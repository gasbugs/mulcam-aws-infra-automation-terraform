"""Extract resource-to-resource references (edges) from parsed configs."""

import re
import json

# Patterns to find references in HCL values (python-hcl2 wraps in ${...})
# Match both ${aws_type.name.attr} and bare aws_type.name.attr
RESOURCE_REF = re.compile(r'(?:\$\{)?(?:([a-z][a-z0-9_]*)\.)?(aws_[a-z0-9_]+)\.([a-z0-9_]+)\.([a-z0-9_\[\]]+)')
MODULE_REF = re.compile(r'(?:\$\{)?module\.([a-z0-9_-]+)\.([a-z0-9_\[\]]+)')
DATA_REF = re.compile(r'(?:\$\{)?data\.([a-z0-9_]+)\.([a-z0-9_]+)\.([a-z0-9_\[\]]+)')


def resolve_references(resources, data_sources, registry_modules):
    """Extract edges between resources based on attribute references."""
    edges = []
    seen = set()

    # Build set of known resource IDs
    known_ids = set()
    for r in resources:
        known_ids.add(r["id"])
    for d in data_sources:
        known_ids.add(d["id"])
    for m in registry_modules:
        known_ids.add(m["id"])

    # Scan each resource's config for references
    for res in resources:
        config_str = json.dumps(res.get("config", {}), default=str)
        source_id = res["id"]

        # Find resource references: pattern captures (prefix, type, name, attr)
        for match in RESOURCE_REF.finditer(config_str):
            prefix, res_type, res_name, attr = match.groups()
            # Skip if prefix is a non-resource like 'local' or 'var'
            if prefix and prefix in ('var', 'local', 'each', 'self', 'count', 'terraform'):
                continue
            target_id = f"{res_type}.{res_name}"
            # Clean attr of brackets
            clean_attr = attr.split('[')[0] if '[' in attr else attr
            if target_id == source_id:
                continue
            if target_id in known_ids:
                edge_key = (source_id, target_id)
                if edge_key not in seen:
                    seen.add(edge_key)
                    edges.append({
                        "from": source_id,
                        "to": target_id,
                        "via": clean_attr,
                        "type": _edge_type(clean_attr),
                    })
            else:
                # Try with module prefix from source
                if "from_module" in res:
                    prefixed = f"module.{res['from_module']}.{target_id}"
                    if prefixed in known_ids:
                        edge_key = (source_id, prefixed)
                        if edge_key not in seen:
                            seen.add(edge_key)
                            edges.append({
                                "from": source_id,
                                "to": prefixed,
                                "via": clean_attr,
                                "type": _edge_type(clean_attr),
                            })

        # Find module references
        for match in MODULE_REF.finditer(config_str):
            mod_name, output = match.groups()
            target_id = f"module.{mod_name}"
            clean_output = output.split('[')[0] if '[' in output else output
            if target_id in known_ids:
                edge_key = (source_id, target_id)
                if edge_key not in seen:
                    seen.add(edge_key)
                    edges.append({
                        "from": source_id,
                        "to": target_id,
                        "via": clean_output,
                        "type": _edge_type(clean_output),
                    })

        # Find data source references
        for match in DATA_REF.finditer(config_str):
            data_type, data_name, attr = match.groups()
            target_id = f"data.{data_type}.{data_name}"
            clean_attr = attr.split('[')[0] if '[' in attr else attr
            if target_id in known_ids:
                edge_key = (source_id, target_id)
                if edge_key not in seen:
                    seen.add(edge_key)
                    edges.append({
                        "from": source_id,
                        "to": target_id,
                        "via": clean_attr,
                        "type": "data",
                    })

    return edges


def _edge_type(attr):
    """Determine edge type from attribute name."""
    if attr in ('vpc_id', 'subnet_id', 'subnet_ids', 'subnets',
                'public_subnets', 'private_subnets', 'database_subnets',
                'security_groups', 'security_group_id', 'vpc_security_group_ids'):
        return "network"
    if attr in ('role', 'role_arn', 'execution_role_arn', 'task_role_arn',
                'instance_profile', 'iam_role_arn', 'policy_arn'):
        return "iam"
    if attr in ('target_group_arn', 'load_balancer_arn', 'listener_arn'):
        return "loadbalancer"
    return "reference"
