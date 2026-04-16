"""Scan repository for Terraform project directories."""

import os
import re

_SKIP_DIRS = {'.terraform', '.git', '__MACOSX', 'node_modules', '.github', 'vendor'}


def _tf_files_in(path):
    try:
        return [f for f in os.listdir(path)
                if f.endswith('.tf') and os.path.isfile(os.path.join(path, f))]
    except OSError:
        return []


def scan_projects(repo_root):
    """Find all Terraform project directories grouped by module.

    Supports two layouts:
    1. Structured (NN_module_name/project_dir/) — our own repo format
    2. Generic — any external repo; collects all dirs containing .tf files
    """
    entries = sorted(os.listdir(repo_root))
    module_dirs = [e for e in entries if re.match(r'^\d{2}_', e) and
                   os.path.isdir(os.path.join(repo_root, e))]

    if module_dirs:
        return _scan_structured(repo_root, module_dirs)
    else:
        return _scan_generic(repo_root)


def _scan_structured(repo_root, module_dirs):
    """Original structured scan for NN_module_name layout."""
    modules = []
    for module_dir in module_dirs:
        module_path = os.path.join(repo_root, module_dir)
        projects = []

        for item in sorted(os.listdir(module_path)):
            item_path = os.path.join(module_path, item)
            if not os.path.isdir(item_path):
                continue
            tf_files = _tf_files_in(item_path)
            if not tf_files:
                # Check one level deeper
                for sub in sorted(os.listdir(item_path)):
                    sub_path = os.path.join(item_path, sub)
                    if os.path.isdir(sub_path) and sub not in _SKIP_DIRS:
                        sub_tf = _tf_files_in(sub_path)
                        if sub_tf:
                            rel_path = os.path.relpath(sub_path, repo_root)
                            projects.append({
                                "name": f"{item}/{sub}",
                                "path": rel_path,
                                "abs_path": sub_path,
                                "tf_files": len(sub_tf),
                                "has_modules": os.path.isdir(os.path.join(sub_path, 'modules')),
                            })
                continue

            rel_path = os.path.relpath(item_path, repo_root)
            projects.append({
                "name": item,
                "path": rel_path,
                "abs_path": item_path,
                "tf_files": len(tf_files),
                "has_modules": os.path.isdir(os.path.join(item_path, 'modules')),
            })

        if projects:
            modules.append({
                "module": module_dir,
                "label": module_dir.replace('_', ' ').title(),
                "projects": projects,
            })
    return modules


def _scan_generic(repo_root):
    """Generic scan: collect all dirs (up to 4 levels deep) with .tf files.

    Groups projects by their immediate parent directory relative to repo_root.
    If repo_root itself has .tf files, it's treated as a single project.
    """
    # Check if root itself is a terraform project
    root_tf = _tf_files_in(repo_root)
    if root_tf:
        name = os.path.basename(repo_root) or 'project'
        return [{
            "module": name,
            "label": name,
            "projects": [{
                "name": name,
                "path": ".",
                "abs_path": repo_root,
                "tf_files": len(root_tf),
                "has_modules": os.path.isdir(os.path.join(repo_root, 'modules')),
            }]
        }]

    # Collect all tf dirs up to 4 levels deep
    tf_dirs = []  # list of (rel_path, abs_path, tf_count)

    def _walk(cur_path, depth):
        if depth > 4:
            return
        try:
            children = sorted(os.listdir(cur_path))
        except OSError:
            return
        for entry in children:
            if entry in _SKIP_DIRS or entry.startswith('.'):
                continue
            full = os.path.join(cur_path, entry)
            if not os.path.isdir(full):
                continue
            tf = _tf_files_in(full)
            if tf:
                tf_dirs.append((os.path.relpath(full, repo_root), full, len(tf)))
            else:
                _walk(full, depth + 1)

    _walk(repo_root, 1)

    if not tf_dirs:
        return []

    # Group by top-level directory under repo_root
    groups = {}
    for rel, abs_path, count in tf_dirs:
        parts = rel.split(os.sep)
        group_key = parts[0] if len(parts) > 1 else '.'
        if group_key not in groups:
            groups[group_key] = []
        groups[group_key].append({
            "name": rel,
            "path": rel,
            "abs_path": abs_path,
            "tf_files": count,
            "has_modules": os.path.isdir(os.path.join(abs_path, 'modules')),
        })

    modules = []
    for group_key in sorted(groups):
        label = group_key if group_key != '.' else os.path.basename(repo_root)
        modules.append({
            "module": label,
            "label": label,
            "projects": groups[group_key],
        })
    return modules
