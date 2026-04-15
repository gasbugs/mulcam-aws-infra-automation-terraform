"""Scan repository for Terraform project directories."""

import os
import re


def scan_projects(repo_root):
    """Find all Terraform project directories grouped by module."""
    modules = []

    entries = sorted(os.listdir(repo_root))
    module_dirs = [e for e in entries if re.match(r'^\d{2}_', e) and
                   os.path.isdir(os.path.join(repo_root, e))]

    for module_dir in module_dirs:
        module_path = os.path.join(repo_root, module_dir)
        projects = []

        for item in sorted(os.listdir(module_path)):
            item_path = os.path.join(module_path, item)
            if not os.path.isdir(item_path):
                continue
            # Check if directory has .tf files directly (not just in modules/)
            tf_files = [f for f in os.listdir(item_path)
                        if f.endswith('.tf') and os.path.isfile(os.path.join(item_path, f))]
            if not tf_files:
                # Check one level deeper for nested projects
                for sub in sorted(os.listdir(item_path)):
                    sub_path = os.path.join(item_path, sub)
                    if os.path.isdir(sub_path) and sub != 'modules' and sub != '.terraform':
                        sub_tf = [f for f in os.listdir(sub_path)
                                  if f.endswith('.tf') and os.path.isfile(os.path.join(sub_path, f))]
                        if sub_tf:
                            rel_path = os.path.relpath(sub_path, repo_root)
                            has_modules = os.path.isdir(os.path.join(sub_path, 'modules'))
                            projects.append({
                                "name": f"{item}/{sub}",
                                "path": rel_path,
                                "abs_path": sub_path,
                                "tf_files": len(sub_tf),
                                "has_modules": has_modules,
                            })
                continue

            rel_path = os.path.relpath(item_path, repo_root)
            has_modules = os.path.isdir(os.path.join(item_path, 'modules'))
            projects.append({
                "name": item,
                "path": rel_path,
                "abs_path": item_path,
                "tf_files": len(tf_files),
                "has_modules": has_modules,
            })

        if projects:
            modules.append({
                "module": module_dir,
                "label": module_dir.replace('_', ' ').title(),
                "projects": projects,
            })

    return modules
