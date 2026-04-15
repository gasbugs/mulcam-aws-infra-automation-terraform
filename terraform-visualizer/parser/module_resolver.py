"""
Resolve module sources into concrete resources.

Strategy:
1. Local modules (./modules/...) → parse directly and inline
2. Registry modules → run `terraform init` to download, read modules.json,
   then parse the actual downloaded source code
"""

import os
import json
import subprocess
import threading

from .hcl_parser import parse_tf_directory

# Cache: project_dir -> init result (thread-safe via lock per dir)
_init_cache = {}
_init_locks = {}
_cache_lock = threading.Lock()


def resolve_modules(modules, project_dir, variables=None):
    """Resolve module blocks into concrete resources."""
    resolved_resources = []
    resolved_stubs = []   # modules we couldn't fully expand

    if not modules:
        return {"resources": resolved_resources, "registry_modules": resolved_stubs}

    # Check if any module needs registry resolution
    has_registry = any(
        not (m.get("source", "").startswith("./") or m.get("source", "").startswith("../"))
        for m in modules
    )

    # Build module dir map from modules.json if available (or after init)
    module_dir_map = {}
    if has_registry:
        module_dir_map = _get_module_dir_map(project_dir)

    for mod in modules:
        source = mod.get("source", "")
        mod_name = mod["name"]

        if source.startswith("./") or source.startswith("../"):
            # Local module
            _resolve_local_module(mod, mod_name, source, project_dir,
                                  resolved_resources, resolved_stubs)
        else:
            # Registry module — use downloaded source from .terraform/modules/
            mod_dir = module_dir_map.get(mod_name)
            if mod_dir and os.path.isdir(mod_dir):
                _resolve_downloaded_module(mod, mod_name, source, mod_dir, variables,
                                           resolved_resources, resolved_stubs)
            else:
                # No download available — show as stub
                resolved_stubs.append(_make_stub(mod_name, source, mod.get("config", {})))

    return {
        "resources": resolved_resources,
        "registry_modules": resolved_stubs,
    }


def _resolve_local_module(mod, mod_name, source, project_dir,
                           resolved_resources, resolved_stubs):
    """Parse a local module directory and inline its resources."""
    mod_path = os.path.normpath(os.path.join(project_dir, source))
    if not os.path.isdir(mod_path):
        return
    parsed = parse_tf_directory(mod_path)
    for res in parsed["resources"]:
        res["id"] = f"module.{mod_name}.{res['id']}"
        res["name"] = f"{mod_name}.{res['name']}"
        res["from_module"] = mod_name
        resolved_resources.append(res)
    # Recurse for nested modules
    if parsed["modules"]:
        nested = resolve_modules(parsed["modules"], mod_path, parsed["variables"])
        for nr in nested["resources"]:
            nr["id"] = f"module.{mod_name}.{nr['id']}"
            resolved_resources.append(nr)
        resolved_stubs.extend(nested["registry_modules"])


def _resolve_downloaded_module(mod, mod_name, source, mod_dir, parent_variables,
                                resolved_resources, resolved_stubs):
    """Parse an already-downloaded registry module and inline its resources."""
    try:
        parsed = parse_tf_directory(mod_dir)
    except Exception:
        resolved_stubs.append(_make_stub(mod_name, source, mod.get("config", {})))
        return

    # Caller-supplied inputs (what the parent module passes to this module)
    mod_config = mod.get("config", {})
    caller_inputs = {k: v for k, v in mod_config.items()
                     if k not in ("source", "version", "depends_on", "count",
                                  "for_each", "providers")}

    # Evaluate locals with effective variables to support count filtering
    effective_vars = _build_effective_vars(parsed["variables"], caller_inputs)
    locals_ = _evaluate_locals(parsed.get("locals", {}), effective_vars)

    # Filter resources using both vars and locals
    filtered = _filter_active_resources_with_locals(
        parsed["resources"], effective_vars, locals_)

    for res in filtered:
        res["id"] = f"module.{mod_name}.{res['id']}"
        res["name"] = f"{mod_name}.{res['name']}"
        res["from_module"] = mod_name
        res["module_source"] = source
        resolved_resources.append(res)

    # Handle nested sub-modules (e.g. eks -> eks-managed-node-group)
    if parsed["modules"]:
        sub_module_dir_map = _get_module_dir_map(mod_dir)
        for sub_mod in parsed["modules"]:
            sub_name = sub_mod["name"]
            sub_source = sub_mod.get("source", "")
            if sub_source.startswith("./") or sub_source.startswith("../"):
                sub_path = os.path.normpath(os.path.join(mod_dir, sub_source))
                if os.path.isdir(sub_path):
                    sub_parsed = parse_tf_directory(sub_path)
                    for res in sub_parsed["resources"]:
                        res["id"] = f"module.{mod_name}.module.{sub_name}.{res['id']}"
                        res["name"] = f"{mod_name}.{sub_name}.{res['name']}"
                        res["from_module"] = f"{mod_name}.{sub_name}"
                        resolved_resources.append(res)
            else:
                sub_dir = sub_module_dir_map.get(sub_name)
                if sub_dir and os.path.isdir(sub_dir):
                    sub_parsed = parse_tf_directory(sub_dir)
                    sub_filtered = _filter_active_resources(sub_parsed["resources"],
                                                            sub_parsed["variables"])
                    for res in sub_filtered:
                        res["id"] = f"module.{mod_name}.module.{sub_name}.{res['id']}"
                        res["name"] = f"{mod_name}.{sub_name}.{res['name']}"
                        res["from_module"] = f"{mod_name}.{sub_name}"
                        res["module_source"] = sub_source
                        resolved_resources.append(res)


def _get_module_dir_map(project_dir):
    """
    Get mapping of module_name -> local_dir from .terraform/modules/modules.json.
    If not present, attempt terraform init to create it.
    """
    modules_json = os.path.join(project_dir, ".terraform", "modules", "modules.json")

    if not os.path.exists(modules_json):
        _run_terraform_init(project_dir)

    if not os.path.exists(modules_json):
        return {}

    try:
        with open(modules_json) as f:
            data = json.load(f)
    except Exception:
        return {}

    dir_map = {}
    for entry in data.get("Modules", []):
        key = entry.get("Key", "")
        rel_dir = entry.get("Dir", "")
        if not key or not rel_dir:
            continue
        # Key can be "vpc", "eks", "eks.eks_managed_node_group.workers" etc.
        # We want the top-level key only (before the first dot in nested)
        top_key = key.split(".")[0]
        abs_dir = os.path.join(project_dir, rel_dir)
        if os.path.isdir(abs_dir):
            # More specific key (fewer dots = top-level) gets priority
            if top_key not in dir_map or key.count('.') < dir_map.get(f"_depth_{top_key}", 99):
                dir_map[top_key] = abs_dir
                dir_map[f"_depth_{top_key}"] = key.count('.')
            # Also store full key path for sub-module lookup
            dir_map[key] = abs_dir

    return dir_map


def _run_terraform_init(project_dir):
    """Run terraform init -backend=false to download modules."""
    with _cache_lock:
        if project_dir not in _init_locks:
            _init_locks[project_dir] = threading.Lock()
        lock = _init_locks[project_dir]

    with lock:
        if _init_cache.get(project_dir) == "done":
            return
        if _init_cache.get(project_dir) == "failed":
            return

        try:
            result = subprocess.run(
                ["terraform", "init", "-backend=false", "-no-color",
                 "-input=false"],
                cwd=project_dir,
                capture_output=True,
                text=True,
                timeout=120,
            )
            if result.returncode == 0:
                _init_cache[project_dir] = "done"
            else:
                _init_cache[project_dir] = "failed"
        except Exception:
            _init_cache[project_dir] = "failed"


def _build_effective_vars(module_variables, caller_inputs):
    """
    Build effective variable map by overriding module defaults with caller inputs.
    Returns dict of var_name -> resolved_value.
    """
    effective = {}
    for name, info in module_variables.items():
        effective[name] = info.get("default")
    # Apply caller-supplied values (strip quote wrappers from HCL strings)
    for k, v in caller_inputs.items():
        if isinstance(v, str) and v.startswith('"') and v.endswith('"'):
            effective[k] = v[1:-1]
        elif v is not None:
            effective[k] = v
    return effective


def _evaluate_locals(locals_map, effective_vars):
    """
    Evaluate terraform locals expressions iteratively.
    Handles simple patterns: length(var.x), local.x, var.x, boolean logic.
    Returns dict of local_name -> Python value.
    """
    import re
    resolved = {}
    # Up to 5 passes to handle inter-local dependencies
    for _ in range(5):
        for key, expr in locals_map.items():
            if key in resolved:
                continue
            val = _eval_expr(str(expr), effective_vars, resolved)
            if val is not None:
                resolved[key] = val
    return resolved


def _eval_expr(expr, vars_, locals_):
    """
    Evaluate a single HCL expression. Returns Python bool/int/str or None
    if the expression cannot be statically determined.
    """
    import re
    # Strip ${ } wrapper
    expr = re.sub(r'^\$\{(.+)\}$', r'\1', expr.strip())
    expr = expr.strip()

    # Boolean literals
    if expr == 'true':  return True
    if expr == 'false': return False
    if expr == 'null':  return None

    # Integer literal
    try:
        return int(expr)
    except ValueError:
        pass

    # var.NAME
    m = re.fullmatch(r'var\.(\w+)', expr)
    if m:
        v = vars_.get(m.group(1))
        return v

    # local.NAME
    m = re.fullmatch(r'local\.(\w+)', expr)
    if m:
        return locals_.get(m.group(1))

    # length(var.NAME) or length(local.NAME)
    m = re.fullmatch(r'length\(var\.(\w+)\)', expr)
    if m:
        v = vars_.get(m.group(1))
        return len(v) if isinstance(v, (list, dict, str)) else 0

    m = re.fullmatch(r'length\(local\.(\w+)\)', expr)
    if m:
        v = locals_.get(m.group(1))
        return len(v) if isinstance(v, (list, dict, str)) else 0

    # max(length(var.A), length(var.B), ...)
    m = re.fullmatch(r'max\((.+)\)', expr)
    if m:
        parts = [p.strip() for p in m.group(1).split(',')]
        vals = [_eval_expr(p, vars_, locals_) for p in parts]
        nums = [v for v in vals if isinstance(v, int)]
        return max(nums) if nums else None

    # local.X && var.Y  /  local.X && local.Y  (boolean AND)
    if ' && ' in expr:
        parts = re.split(r'\s*&&\s*', expr)
        results = [_eval_expr(p.strip(), vars_, locals_) for p in parts]
        if any(r is False or r == 0 or r == [] for r in results):
            return False
        if all(r is not None for r in results):
            return bool(all(results))
        return None

    # X > 0
    m = re.fullmatch(r'(.+)\s*>\s*0', expr)
    if m:
        v = _eval_expr(m.group(1).strip(), vars_, locals_)
        if isinstance(v, int):
            return v > 0
        return None

    # X != "something"
    m = re.fullmatch(r'(.+)\s*!=\s*"([^"]*)"', expr)
    if m:
        v = _eval_expr(m.group(1).strip(), vars_, locals_)
        if v is not None:
            return str(v) != m.group(2)
        return None

    # !var.X or !local.X
    m = re.fullmatch(r'!(.+)', expr)
    if m:
        v = _eval_expr(m.group(1).strip(), vars_, locals_)
        if v is not None:
            return not bool(v)
        return None

    # Ternary: CONDITION ? TRUE_EXPR : FALSE_EXPR
    # Use simple split but handle nested parens
    ternary = _split_ternary(expr)
    if ternary:
        cond_expr, true_expr, false_expr = ternary
        cond = _eval_expr(cond_expr, vars_, locals_)
        if cond is True:
            return _eval_expr(true_expr, vars_, locals_)
        if cond is False or cond == 0:
            return _eval_expr(false_expr, vars_, locals_)
        return None

    return None  # Cannot evaluate statically


def _split_ternary(expr):
    """Split a ternary expression 'A ? B : C' into (A, B, C). Returns None if not ternary."""
    # Track depth for parens/brackets
    depth = 0
    q_pos = None
    c_pos = None
    for i, ch in enumerate(expr):
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        elif ch == '?' and depth == 0 and q_pos is None:
            q_pos = i
        elif ch == ':' and depth == 0 and q_pos is not None and c_pos is None:
            c_pos = i
    if q_pos and c_pos and q_pos < c_pos:
        cond = expr[:q_pos].strip()
        true_expr = expr[q_pos+1:c_pos].strip()
        false_expr = expr[c_pos+1:].strip()
        return cond, true_expr, false_expr
    return None


def _filter_active_resources(resources, variables, caller_inputs=None):
    """Simple filter used for top-level project resources."""
    import re
    effective_vars = _build_effective_vars(variables, caller_inputs or {})
    return _filter_active_resources_with_locals(resources, effective_vars, {})


def _filter_active_resources_with_locals(resources, effective_vars, locals_):
    """Filter out resources where count evaluates to 0, using locals context."""
    active = []
    for res in resources:
        count = res.get("count")
        if count is None:
            active.append(res)
            continue
        if isinstance(count, int):
            if count == 0:
                continue
            active.append(res)
            continue
        if isinstance(count, str):
            count_str = str(count).strip()
            if count_str in ("0", "${0}"):
                continue
            val = _eval_expr(count_str, effective_vars, locals_)
            if val is False or val == 0:
                continue
        active.append(res)
    return active


def _make_stub(name, source, config):
    """Fallback stub when a module can't be expanded."""
    return {
        "name": name,
        "id": f"module.{name}",
        "source": source,
        "type": "registry_module",
        "icon": _guess_icon(source),
        "category": _guess_category(source),
        "label": f"Module: {name} ({source.split('/')[-1]})",
        "sub_resources": [],
        "config": config,
    }


def _guess_icon(source):
    s = source.lower()
    if "vpc" in s: return "vpc"
    if "eks" in s: return "eks"
    if "iam" in s: return "iam_role"
    if "s3" in s: return "s3"
    if "ecr" in s: return "ecr"
    if "ec2" in s: return "ec2"
    if "rds" in s: return "rds"
    return "module"


def _guess_category(source):
    s = source.lower()
    if "vpc" in s or "subnet" in s: return "networking"
    if "eks" in s or "ecs" in s or "ecr" in s: return "container"
    if "iam" in s: return "iam"
    if "s3" in s: return "storage"
    if "rds" in s or "aurora" in s: return "database"
    return "other"
