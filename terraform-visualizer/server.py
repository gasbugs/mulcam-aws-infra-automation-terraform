"""Flask server for Terraform Infrastructure Visualizer."""

import argparse
import os
import json
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
    if not path:
        return jsonify({"error": "path parameter required"}), 400

    project_dir = os.path.join(REPO_ROOT, path)
    if not os.path.isdir(project_dir):
        return jsonify({"error": f"directory not found: {path}"}), 404

    # Check cache
    cache_key = path
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

    # Annotate resources with visual metadata
    annotated = []
    for res in active_resources:
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
            "file": res.get("file", ""),
            "from_module": res.get("from_module"),
            "module_source": res.get("module_source", ""),
            "hidden": is_hidden(res["type"]),
            "structural": is_structural(res["type"]),
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

    # Resolve references (pass all registry stubs so edges to them still work)
    edges = resolve_references(active_resources, parsed["data_sources"], registry_modules)

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

    result = {
        "path": path,
        "resources": annotated,
        "registry_modules": annotated_modules,
        "data_sources": annotated_data,
        "edges": edges,
        "warnings": parsed.get("warnings", []),
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
