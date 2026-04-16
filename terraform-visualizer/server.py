"""Flask server for Terraform Infrastructure Visualizer."""

import argparse
import os
import json
import zipfile
import uuid
import shutil
import urllib.request as _urlreq
from flask import Flask, jsonify, send_from_directory, request

from parser.project_scanner import scan_projects
from parser.hcl_parser import parse_tf_directory
from parser.module_resolver import resolve_modules
from parser.reference_resolver import resolve_references
from parser.resource_catalog import (
    get_category, get_icon, get_zone, get_color,
    is_hidden, is_structural,
    CATEGORIES,
)

app = Flask(__name__, static_folder='static')
REPO_ROOT = None
_cache = {}

UPLOAD_DIR = '/tmp/tf-viz-uploads'
_upload_repos = {}  # repo_id -> absolute directory path
os.makedirs(UPLOAD_DIR, exist_ok=True)


@app.route('/')
def index():
    return send_from_directory('static', 'index.html')


@app.route('/css/<path:filename>')
def css(filename):
    return send_from_directory('static/css', filename)


@app.route('/js/<path:filename>')
def js(filename):
    return send_from_directory('static/js', filename)


@app.route('/api/projects')
def api_projects():
    modules = scan_projects(REPO_ROOT)
    return jsonify(modules)


@app.route('/api/project')
def api_project():
    path = request.args.get('path', '')
    repo_id = request.args.get('repo_id', '')
    if not path:
        return jsonify({"error": "path parameter required"}), 400

    if repo_id:
        base_dir = _upload_repos.get(repo_id)
        if not base_dir:
            return jsonify({"error": f"Unknown repo_id: {repo_id}"}), 404
    else:
        base_dir = REPO_ROOT

    project_dir = os.path.join(base_dir, path)
    if not os.path.isdir(project_dir):
        return jsonify({"error": f"directory not found: {path}"}), 404

    # Check cache (include repo_id in key)
    cache_key = f"{repo_id}::{path}" if repo_id else path
    mtime = _get_dir_mtime(project_dir)
    if cache_key in _cache and _cache[cache_key]["mtime"] == mtime:
        return jsonify(_cache[cache_key]["data"])

    # Parse the project
    parsed = parse_tf_directory(project_dir)

    # Resolve modules
    module_result = resolve_modules(parsed["modules"], project_dir, parsed["variables"])

    # Combine all resources
    all_resources = parsed["resources"] + module_result["resources"]
    registry_modules = module_result["registry_modules"]

    # Filter out disabled resources (count = 0)
    active_resources = _filter_active(all_resources, parsed["variables"])

    # Resolve references first (needed for attached_sgs computation)
    edges = resolve_references(active_resources, parsed["data_sources"], registry_modules)

    # Build attached_sgs: resource_id → list of {id, name, file} for SGs attached to it
    # Security group is rendered as a badge on the resource, not as a standalone node
    sg_info_map = {
        res["id"]: {
            "id": res["id"],
            "name": res["name"],
            "file": res.get("file", ""),
        }
        for res in active_resources
        if res["type"] == "aws_security_group"
    }
    attached_sgs_map = {}
    for edge in edges:
        # Resource → SG edge: the resource has this SG attached
        if edge["to"] in sg_info_map:
            lst = attached_sgs_map.setdefault(edge["from"], [])
            info = sg_info_map[edge["to"]]
            if not any(x["id"] == info["id"] for x in lst):
                lst.append(info)
        # SG → Resource edge (e.g., SG references another SG)
        if edge["from"] in sg_info_map:
            lst = attached_sgs_map.setdefault(edge["to"], [])
            info = sg_info_map[edge["from"]]
            if not any(x["id"] == info["id"] for x in lst):
                lst.append(info)

    # Detect S3 bucket roles based on edge connections
    # Each S3 bucket is classified by how it's actually used in the architecture
    _S3_CDN_TYPES = frozenset({
        'aws_cloudfront_distribution', 'aws_cloudfront_origin_access_control',
        'aws_cloudfront_origin_access_identity',
    })
    _S3_CICD_TYPES = frozenset({
        'aws_codepipeline', 'aws_codebuild_project',
    })
    _S3_LAMBDA_TYPES = frozenset({
        'aws_lambda_function', 'aws_lambda_layer_version',
    })
    _S3_LOG_TYPES = frozenset({
        'aws_lb', 'aws_alb', 'aws_cloudtrail', 'aws_flow_log',
        'aws_kinesis_firehose_delivery_stream', 'aws_config_delivery_channel',
        'aws_cloudwatch_log_group',
    })
    _S3_API_TYPES = frozenset({
        'aws_api_gateway_rest_api', 'aws_apigatewayv2_api',
    })

    _res_id_to_type = {r["id"]: r["type"] for r in active_resources}
    _s3_roles = {}
    for res in active_resources:
        if res["type"] != "aws_s3_bucket":
            continue
        sid = res["id"]
        connected = set()
        for edge in edges:
            if edge["from"] == sid:
                connected.add(_res_id_to_type.get(edge["to"], ""))
            if edge["to"] == sid:
                connected.add(_res_id_to_type.get(edge["from"], ""))

        name_lower = res["name"].lower()
        if connected & _S3_CDN_TYPES:
            role = "cdn"           # CloudFront 오리진 버킷 → external 존 (CDN 패널)
        elif connected & _S3_CICD_TYPES:
            role = "artifact"      # CI/CD 파이프라인 아티팩트 → cicd 존
        elif connected & _S3_LAMBDA_TYPES:
            role = "lambda"        # Lambda 배포 패키지 → private 존 (Lambda 옆)
        elif connected & _S3_API_TYPES:
            role = "api"           # API Gateway 관련 → private 존
        elif (connected & _S3_LOG_TYPES or
              any(kw in name_lower for kw in ("log", "logging", "audit", "trail", "access-log", "accesslog"))):
            role = "log"           # 로그 저장소 → side 존 (모니터링 옆)
        else:
            role = "general"       # 일반 오브젝트 스토리지 → external 존
        _s3_roles[sid] = role

    # Determine which SGs are "attached" (appear as badge on at least one resource)
    attached_sg_ids = {
        sg["id"]
        for sgs in attached_sgs_map.values()
        for sg in sgs
    }

    # Build attached_ebs: EC2 instance id → list of {id, name, file}
    # Linked via aws_volume_attachment which references both instance_id and volume_id
    ebs_info_map = {
        res["id"]: {"id": res["id"], "name": res["name"], "file": res.get("file", "")}
        for res in active_resources
        if res["type"] == "aws_ebs_volume"
    }
    ec2_ids = {res["id"] for res in active_resources if res["type"] == "aws_instance"}

    attached_ebs_map = {}
    for res in active_resources:
        if res["type"] != "aws_volume_attachment":
            continue
        connected_ec2, connected_ebs = None, None
        for edge in edges:
            if edge["from"] == res["id"]:
                other = edge["to"]
            elif edge["to"] == res["id"]:
                other = edge["from"]
            else:
                continue
            if other in ec2_ids:
                connected_ec2 = other
            elif other in ebs_info_map:
                connected_ebs = other
        if connected_ec2 and connected_ebs:
            lst = attached_ebs_map.setdefault(connected_ec2, [])
            info = ebs_info_map[connected_ebs]
            if not any(x["id"] == info["id"] for x in lst):
                lst.append(info)

    # Check if project uses default VPC infrastructure (default_vpc / default_subnet resources)
    _default_subnet_ids = {
        r["id"] for r in active_resources if r["type"] == "aws_default_subnet"
    }
    _uses_default_vpc = any(
        r["type"] in ("aws_default_vpc", "aws_default_subnet")
        for r in active_resources
    )

    # Compute types that could be placed in the default VPC
    _COMPUTE_TYPES = {
        "aws_instance", "aws_launch_template", "aws_autoscaling_group",
        "aws_ecs_service", "aws_ecs_task_definition",
        "aws_eks_cluster", "aws_eks_node_group",
        "aws_lb", "aws_alb",
    }

    # ── Public IP status detection ──────────────────────────────────────────
    # Build set of resource IDs that have an EIP edge (aws_eip → resource or resource → aws_eip)
    _eip_ids = {r["id"] for r in active_resources if r["type"] == "aws_eip"}
    _eip_attached_to = set()          # resource IDs with an EIP attached
    for _edge in edges:
        if _edge["from"] in _eip_ids:
            _eip_attached_to.add(_edge["to"])
        if _edge["to"] in _eip_ids:
            _eip_attached_to.add(_edge["from"])

    # Subnets that auto-assign public IPs (map_public_ip_on_launch = true)
    _public_subnet_ids = set()
    for r in active_resources:
        if r["type"] in ("aws_subnet", "aws_default_subnet"):
            cfg = r.get("config", {})
            if cfg.get("map_public_ip_on_launch") is True:
                _public_subnet_ids.add(r["id"])

    def _detect_public_ip(res, res_id):
        """Return 'assigned', 'likely', or None.

        'assigned' — confirmed: EIP attached, or associate_public_ip_address=true,
                     or LB internet-facing, or RDS publicly_accessible
        'likely'   — probable: default VPC instance with no explicit override,
                     or in a subnet with map_public_ip_on_launch
        None       — internal / unknown
        """
        rtype = res["type"]
        config = res.get("config", {})

        # 1. Direct EIP attachment (aws_eip → this resource)
        if res_id in _eip_attached_to:
            return "assigned"

        # 2. associate_public_ip_address = true in resource config
        assoc = config.get("associate_public_ip_address")
        if assoc is True or str(assoc).lower() in ("true", "1"):
            return "assigned"

        # 3. network_interface block with associate_public_ip_address = true
        ni = config.get("network_interface", [])
        if isinstance(ni, dict):
            ni = [ni]
        if isinstance(ni, list):
            for ni_block in ni:
                if isinstance(ni_block, dict):
                    a = ni_block.get("associate_public_ip_address")
                    if a is True or str(a).lower() in ("true", "1"):
                        return "assigned"

        # 4. RDS publicly_accessible
        if rtype in ("aws_db_instance", "aws_rds_cluster", "aws_rds_cluster_instance"):
            pub = config.get("publicly_accessible")
            if pub is True or str(pub).lower() in ("true", "1"):
                return "assigned"
            return None   # explicit false or omitted → internal by default

        # 5. Load Balancer: internet-facing by default (internal=false or absent → public)
        if rtype in ("aws_lb", "aws_alb"):
            internal = config.get("internal")
            if internal is True or str(internal).lower() == "true":
                return None   # internal ALB
            return "assigned"   # internet-facing (default)

        # 6. NAT Gateway always has a public EIP (even if not yet resolved via edges)
        if rtype == "aws_nat_gateway":
            return "assigned"

        # 7. Instance in a subnet with map_public_ip_on_launch
        if rtype == "aws_instance":
            sid_ref = str(config.get("subnet_id", ""))
            for psid in _public_subnet_ids:
                if psid in sid_ref:
                    return "likely"

        # 8. Default VPC: compute resources get a public IP unless explicitly set to false
        if _uses_default_vpc and rtype in (
            "aws_instance", "aws_autoscaling_group", "aws_launch_template"
        ):
            # Only if associate_public_ip_address is not explicitly false
            if assoc is not False and str(assoc).lower() != "false":
                return "likely"

        return None

    def _detect_subnet_placement(config, resource_type=None):
        """Return 'public' or 'private' based on subnet reference strings, or None."""
        refs = []
        for key in ('subnet_id', 'subnet_ids', 'subnets', 'subnet'):
            val = config.get(key)
            if val is None:
                continue
            if isinstance(val, list):
                refs.extend(str(v) for v in val)
            else:
                refs.append(str(val))
        ref_str = ' '.join(refs).lower()
        if ref_str:
            # explicit "default" subnet reference → public (default VPC subnets are public)
            if 'default' in ref_str:
                return 'public'
            if 'public' in ref_str:
                return 'public'
            if 'private' in ref_str:
                return 'private'
        else:
            # No subnet specified: if project uses default VPC and resource is compute → public
            if _uses_default_vpc and resource_type in _COMPUTE_TYPES:
                return 'public'
        return None

    # Annotate resources with visual metadata
    annotated = []
    for res in active_resources:
        file_dir = res.get("file_dir", project_dir)
        file_name = res.get("file", "")
        is_sg = res["type"] == "aws_security_group"
        # SGs from a module are associated with that module — not orphan
        sg_orphan = is_sg and res["id"] not in attached_sg_ids and not res.get("from_module")
        # Orphan SGs are normally hidden but we surface them as a separate visual zone
        hidden = is_hidden(res["type"]) and not sg_orphan
        subnet_placement = _detect_subnet_placement(res.get("config", {}), res["type"])
        public_ip_status = _detect_public_ip(res, res["id"])
        annotated.append({
            "id": res["id"],
            "type": res["type"],
            "name": res["name"],
            "category": get_category(res["type"]),
            "icon": get_icon(res["type"]),
            "zone": get_zone(res["type"]),
            "color": get_color(res["type"]),
            "count": res.get("count"),
            "for_each": bool(res.get("for_each")),
            "file": file_name,
            "file_path": os.path.join(file_dir, file_name) if file_name else "",
            "from_module": res.get("from_module"),
            "module_source": res.get("module_source", ""),
            "hidden": hidden,
            "structural": is_structural(res["type"]),
            "attached_sgs": attached_sgs_map.get(res["id"], []),
            "attached_ebs": attached_ebs_map.get(res["id"], []),
            "s3_role": _s3_roles.get(res["id"], ""),
            "sg_orphan": sg_orphan,
            "subnet_placement": subnet_placement,
            "public_ip_status": public_ip_status,
        })

    # Annotate stub modules (ones we couldn't fully expand)
    annotated_modules = []
    for mod in registry_modules:
        annotated_modules.append({
            "id": mod["id"],
            "name": mod["name"],
            "type": "module",
            "label": mod.get("label", f"module.{mod['name']}"),
            "icon": mod.get("icon", "module"),
            "category": mod.get("category", "other"),
            "zone": _module_zone(mod),
            "color": CATEGORIES.get(mod.get("category", ""), {}).get("color", "#888"),
            "sub_resources": mod.get("sub_resources", []),
            "source": mod.get("source", ""),
        })

    # Data sources
    annotated_data = []
    for ds in parsed["data_sources"]:
        annotated_data.append({
            "id": ds["id"],
            "type": ds["type"],
            "name": ds["name"],
            "category": get_category(ds["type"]),
            "icon": get_icon(ds["type"]),
            "zone": "side",
        })

    # Build module file metadata for /api/source
    modules_meta = {
        m["name"]: {
            "file": m.get("file", ""),
            "file_path": os.path.join(project_dir, m.get("file", "")) if m.get("file") else "",
        }
        for m in parsed.get("modules", [])
    }

    result = {
        "path": path,
        "aws_region": parsed.get("aws_region"),
        "resources": annotated,
        "registry_modules": annotated_modules,
        "data_sources": annotated_data,
        "edges": edges,
        "warnings": parsed.get("warnings", []),
        "_modules_meta": modules_meta,
        "stats": {
            "total_resources": len(annotated),
            "total_modules": len(annotated_modules),
            "total_data_sources": len(annotated_data),
            "total_edges": len(edges),
            "categories": _count_categories(annotated),
        },
    }

    _cache[cache_key] = {"mtime": mtime, "data": result}
    return jsonify(result)


@app.route('/api/source')
def api_source():
    project_path = request.args.get('path', '')
    resource_id = request.args.get('id', '')

    if not project_path or not resource_id:
        return jsonify({"error": "path and id required"}), 400

    repo_id = request.args.get('repo_id', '')
    cache_key = f"{repo_id}::{project_path}" if repo_id else project_path
    if cache_key not in _cache:
        return jsonify({"error": "project not loaded — view it first"}), 404

    source_base = _upload_repos.get(repo_id) if repo_id else REPO_ROOT
    cached_data = _cache[cache_key]["data"]
    parts = resource_id.split('.')

    # ── Module stub: "module.vpc" (exactly two parts) ──────────────────
    if parts[0] == 'module' and len(parts) == 2:
        mod_name = parts[1]
        modules_meta = cached_data.get("_modules_meta", {})
        mod_info = modules_meta.get(mod_name, {})
        file_path = mod_info.get("file_path", "")
        if not file_path or not os.path.exists(file_path):
            return jsonify({"error": f"module definition file not found for '{mod_name}'"}), 404
        with open(file_path, 'r') as f:
            content = f.read()
        block = _extract_hcl_block(content, 'module', mod_name, None)
        return jsonify({
            "id": resource_id,
            "file": os.path.relpath(file_path, source_base) if source_base else file_path,
            "source": block or f"# Could not extract module block for '{mod_name}'",
        })

    # ── Data source: "data.type.name" ──────────────────────────────────
    if parts[0] == 'data' and len(parts) >= 3:
        cached_resources = cached_data.get("resources", [])
        resource = next((r for r in cached_resources if r["id"] == resource_id), None)
        if not resource:
            return jsonify({"error": "data source not found"}), 404
        file_path = resource.get("file_path", "")
        if not file_path or not os.path.exists(file_path):
            return jsonify({"error": "source file not found"}), 404
        with open(file_path, 'r') as f:
            content = f.read()
        block = _extract_hcl_block(content, 'data', parts[1], parts[2])
        return jsonify({
            "id": resource_id,
            "file": os.path.relpath(file_path, source_base) if source_base else file_path,
            "source": block or f"# Could not extract block from {os.path.basename(file_path)}",
        })

    # ── Regular or module-expanded resource ────────────────────────────
    cached_resources = cached_data.get("resources", [])
    resource = next((r for r in cached_resources if r["id"] == resource_id), None)
    if not resource:
        return jsonify({"error": "resource not found"}), 404

    file_path = resource.get("file_path", "")
    if not file_path or not os.path.exists(file_path):
        return jsonify({"error": "source file not found", "file": file_path}), 404

    with open(file_path, 'r') as f:
        content = f.read()

    # Last two dot-segments are always resource_type.resource_name
    res_type, res_name = parts[-2], parts[-1]
    block = _extract_hcl_block(content, 'resource', res_type, res_name)
    return jsonify({
        "id": resource_id,
        "file": os.path.relpath(file_path, source_base) if source_base else file_path,
        "source": block or f"# Could not extract block from {os.path.basename(file_path)}",
    })


def _extract_hcl_block(content, block_type, res_type, res_name):
    """Extract a specific resource, data, or module block from HCL file content."""
    import re
    if block_type == 'module':
        pattern = rf'module\s+"?{re.escape(res_type)}"?\s*\{{'
    elif block_type == 'data':
        pattern = rf'data\s+"?{re.escape(res_type)}"?\s+"?{re.escape(res_name)}"?\s*\{{'
    else:
        pattern = rf'resource\s+"?{re.escape(res_type)}"?\s+"?{re.escape(res_name)}"?\s*\{{'

    match = re.search(pattern, content)
    if not match:
        return None

    start = match.start()
    brace_count = 0
    i = match.end() - 1  # position of the opening brace
    while i < len(content):
        if content[i] == '{':
            brace_count += 1
        elif content[i] == '}':
            brace_count -= 1
            if brace_count == 0:
                return content[start:i + 1]
        i += 1
    return content[start:]  # unterminated block fallback


@app.route('/api/upload', methods=['POST'])
def api_upload():
    """Accept a ZIP file, extract to temp dir, scan for Terraform projects."""
    if 'file' not in request.files:
        return jsonify({"error": "No file field in request"}), 400
    f = request.files['file']
    if not f.filename.lower().endswith('.zip'):
        return jsonify({"error": "Only .zip files are supported"}), 400

    repo_id = uuid.uuid4().hex[:10]
    extract_dir = os.path.join(UPLOAD_DIR, repo_id)
    os.makedirs(extract_dir, exist_ok=True)
    try:
        zip_path = os.path.join(extract_dir, '_upload.zip')
        f.save(zip_path)
        with zipfile.ZipFile(zip_path, 'r') as zf:
            zf.extractall(extract_dir)
        os.remove(zip_path)
    except Exception as e:
        shutil.rmtree(extract_dir, ignore_errors=True)
        return jsonify({"error": f"Failed to extract ZIP: {e}"}), 400

    actual_root = _find_root(extract_dir)
    _upload_repos[repo_id] = actual_root
    modules = scan_projects(actual_root)
    name = os.path.splitext(f.filename)[0]
    return jsonify({"repo_id": repo_id, "name": name, "modules": modules})


@app.route('/api/github', methods=['POST'])
def api_github():
    """Download a public GitHub repo as ZIP, extract, scan for projects."""
    data = request.get_json(silent=True) or {}
    url = data.get('url', '').strip()
    if not url:
        return jsonify({"error": "url is required"}), 400

    try:
        user, repo, branch, subpath = _parse_github_url(url)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400

    # Build download URL candidates (prefer specific branch, fallback to HEAD)
    candidates = []
    if branch and branch not in ('main', 'master'):
        candidates.append(f"https://github.com/{user}/{repo}/archive/refs/heads/{branch}.zip")
    candidates.append(f"https://github.com/{user}/{repo}/archive/refs/heads/{branch or 'main'}.zip")
    candidates.append(f"https://github.com/{user}/{repo}/archive/HEAD.zip")

    repo_id = uuid.uuid4().hex[:10]
    extract_dir = os.path.join(UPLOAD_DIR, repo_id)
    os.makedirs(extract_dir, exist_ok=True)

    last_err = None
    for zip_url in candidates:
        try:
            zip_path = os.path.join(extract_dir, '_repo.zip')
            req = _urlreq.Request(zip_url, headers={'User-Agent': 'TerraformVisualizer/1.0'})
            with _urlreq.urlopen(req, timeout=30) as resp:
                with open(zip_path, 'wb') as fh:
                    fh.write(resp.read())
            with zipfile.ZipFile(zip_path, 'r') as zf:
                zf.extractall(extract_dir)
            os.remove(zip_path)
            last_err = None
            break
        except Exception as e:
            last_err = e
            if os.path.exists(zip_path):
                os.remove(zip_path)

    if last_err:
        shutil.rmtree(extract_dir, ignore_errors=True)
        return jsonify({"error": f"Failed to download repository: {last_err}"}), 400

    # Navigate to repo root (usually extracted as repo-branch/)
    actual_root = _find_root(extract_dir)

    # Navigate into subpath if specified (e.g. modules/module-1)
    if subpath:
        sub = os.path.join(actual_root, subpath)
        if os.path.isdir(sub):
            actual_root = sub
        else:
            shutil.rmtree(extract_dir, ignore_errors=True)
            return jsonify({"error": f"Subpath '{subpath}' not found in repository"}), 400

    _upload_repos[repo_id] = actual_root
    modules = scan_projects(actual_root)
    display_name = f"{user}/{repo}" + (f"/{subpath}" if subpath else "")
    return jsonify({"repo_id": repo_id, "name": display_name, "modules": modules})


@app.route('/api/repo/remove', methods=['POST'])
def api_repo_remove():
    """Remove an uploaded repo and its temp files."""
    data = request.get_json(silent=True) or {}
    repo_id = data.get('repo_id', '')
    if repo_id in _upload_repos:
        extract_dir = os.path.join(UPLOAD_DIR, repo_id)
        shutil.rmtree(extract_dir, ignore_errors=True)
        del _upload_repos[repo_id]
        # Clear related cache entries
        for key in list(_cache.keys()):
            if key.startswith(f"{repo_id}::"):
                del _cache[key]
    return jsonify({"ok": True})


def _find_root(extract_dir):
    """If the extracted dir has exactly one subdir, use that as root."""
    try:
        contents = [c for c in os.listdir(extract_dir)
                    if not c.startswith('.') and c != '__MACOSX']
        if len(contents) == 1:
            candidate = os.path.join(extract_dir, contents[0])
            if os.path.isdir(candidate):
                return candidate
    except Exception:
        pass
    return extract_dir


def _parse_github_url(url):
    """Return (user, repo, branch, subpath) from a GitHub URL string.

    Handles:
      https://github.com/user/repo
      https://github.com/user/repo/tree/branch
      https://github.com/user/repo/tree/branch/path/to/subdir
      user/repo
      user/repo@branch
    """
    import re
    url = re.sub(r'^https?://github\.com/', '', url.strip().rstrip('/'))
    # user/repo/tree/branch[/subpath...]
    # branch is the first path segment after 'tree/', rest is subpath
    tree_m = re.match(r'^([^/]+)/([^/@]+)/tree/([^/]+)(/.*)?$', url)
    if tree_m:
        branch = tree_m.group(3)
        subpath = tree_m.group(4).strip('/') if tree_m.group(4) else ''
        return tree_m.group(1), tree_m.group(2), branch, subpath
    at_m = re.match(r'^([^/]+)/([^@]+)@(.+)$', url)
    if at_m:
        return at_m.group(1), at_m.group(2), at_m.group(3), ''
    plain_m = re.match(r'^([^/]+)/([^/]+)$', url)
    if plain_m:
        return plain_m.group(1), plain_m.group(2), '', ''
    raise ValueError(f"Cannot parse GitHub URL: {url!r}. Expected: user/repo or https://github.com/user/repo")


def _filter_active(resources, variables):
    """Remove resources with count=0 or evaluatable false conditions."""
    active = []
    for res in resources:
        count = res.get("count")
        if count is None:
            active.append(res)
            continue
        if isinstance(count, int) and count == 0:
            continue
        if isinstance(count, str):
            # Try to evaluate simple ternary: var.X ? 1 : 0
            if _is_disabled_ternary(count, variables):
                continue
        active.append(res)
    return active


def _is_disabled_ternary(expr, variables):
    """Check if a ternary expression evaluates to 0 given variable defaults."""
    import re
    # Pattern: var.name ? 1 : 0  or  var.name ? 0 : 1
    m = re.match(r'\$\{var\.(\w+)\s*\?\s*(\d+)\s*:\s*(\d+)\}', str(expr))
    if not m:
        m = re.match(r'var\.(\w+)\s*\?\s*(\d+)\s*:\s*(\d+)', str(expr))
    if m:
        var_name, true_val, false_val = m.groups()
        var_info = variables.get(var_name, {})
        default = var_info.get("default")
        if default is True:
            return int(true_val) == 0
        if default is False:
            return int(false_val) != 0
    return False


def _module_zone(mod):
    cat = mod.get("category", "")
    if cat in CATEGORIES:
        return CATEGORIES[cat]["zone"]
    return "private"


def _count_categories(resources):
    counts = {}
    for r in resources:
        cat = r["category"]
        counts[cat] = counts.get(cat, 0) + 1
    return counts


def _get_dir_mtime(directory):
    """Get max mtime of .tf files in directory."""
    max_mtime = 0
    for f in os.listdir(directory):
        if f.endswith('.tf'):
            mtime = os.path.getmtime(os.path.join(directory, f))
            max_mtime = max(max_mtime, mtime)
    return max_mtime


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Terraform Infrastructure Visualizer')
    parser.add_argument('--repo', required=True, help='Path to Terraform repository root')
    parser.add_argument('--port', type=int, default=5000, help='Server port')
    parser.add_argument('--host', default='127.0.0.1', help='Server host')
    args = parser.parse_args()

    REPO_ROOT = os.path.abspath(args.repo)
    print(f"Terraform Visualizer starting...")
    print(f"  Repository: {REPO_ROOT}")
    print(f"  Server: http://{args.host}:{args.port}")
    app.run(host=args.host, port=args.port, debug=True)
