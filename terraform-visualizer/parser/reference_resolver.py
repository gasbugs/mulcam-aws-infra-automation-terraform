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

    # Build lookup: id → resource type (for target-type-based edge classification)
    known_ids = set()
    id_to_type = {}
    for r in resources:
        known_ids.add(r["id"])
        id_to_type[r["id"]] = r.get("type", "")
    for d in data_sources:
        known_ids.add(d["id"])
        id_to_type[d["id"]] = d.get("type", "")
    for m in registry_modules:
        known_ids.add(m["id"])
        id_to_type[m["id"]] = m.get("type", "")

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
                        "type": _edge_type(clean_attr, id_to_type.get(target_id)),
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
                                "type": _edge_type(clean_attr, id_to_type.get(prefixed)),
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

    # Add virtual edges for VPC Endpoint → matched AWS service resources
    _add_vpc_endpoint_edges(resources, edges, seen)

    return edges


# Resource types that represent traffic boundaries / filters
_TRAFFIC_TARGET_TYPES = {
    'aws_security_group',
    'aws_lb', 'aws_alb',
    'aws_lb_target_group', 'aws_alb_target_group',
    'aws_lb_listener', 'aws_alb_listener',
    'aws_vpc_endpoint',
    'aws_api_gateway_rest_api', 'aws_apigatewayv2_api',
    'aws_cloudfront_distribution',
}

# Resource types that represent identity / permission
_PERMISSION_TARGET_TYPES = {
    'aws_iam_role', 'aws_iam_policy', 'aws_iam_instance_profile',
}

# Resource types that represent network placement
_NETWORK_TARGET_TYPES = {
    'aws_vpc', 'aws_subnet',
    'aws_nat_gateway', 'aws_internet_gateway',
    'aws_vpc_peering_connection',
}


def _edge_type(attr, target_type=None):
    """Determine edge type from attribute name and/or target resource type."""
    # Target-type-based classification (most reliable)
    if target_type in _TRAFFIC_TARGET_TYPES:
        return "traffic"
    if target_type in _PERMISSION_TARGET_TYPES:
        return "permission"
    if target_type in _NETWORK_TARGET_TYPES:
        return "network"

    # Attribute-name-based fallback
    # Traffic path: security group attributes + load balancer connections
    if attr in ('security_groups', 'security_group_id', 'vpc_security_group_ids',
                'security_group_ids',
                'target_group_arn', 'load_balancer_arn', 'listener_arn'):
        return "traffic"
    # Network placement: VPC / subnet configuration
    if attr in ('vpc_id', 'subnet_id', 'subnet_ids', 'subnets',
                'public_subnets', 'private_subnets', 'database_subnets'):
        return "network"
    # Permission: IAM roles and policies
    if attr in ('role', 'role_arn', 'execution_role_arn', 'task_role_arn',
                'instance_profile', 'iam_role_arn', 'policy_arn',
                'service_linked_role_arn'):
        return "permission"
    return "reference"


# Maps VPC Endpoint service suffix → AWS resource type
_VPC_ENDPOINT_SERVICE_MAP = {
    's3': 'aws_s3_bucket',
    'dynamodb': 'aws_dynamodb_table',
    'ecr.api': 'aws_ecr_repository',
    'ecr.dkr': 'aws_ecr_repository',
    'secretsmanager': 'aws_secretsmanager_secret',
    'kms': 'aws_kms_key',
    'ssm': 'aws_ssm_parameter',
    'sqs': 'aws_sqs_queue',
    'sns': 'aws_sns_topic',
    'lambda': 'aws_lambda_function',
    'execute-api': 'aws_api_gateway_rest_api',
    'elasticloadbalancing': 'aws_lb',
}


def _add_vpc_endpoint_edges(resources, edges, seen):
    """Generate traffic edges from aws_vpc_endpoint to matched service resources.

    service_name format: com.amazonaws.{region}.{service}
    When the target service resource exists in the project, add a traffic edge.
    """
    for res in resources:
        if res["type"] != "aws_vpc_endpoint":
            continue
        service_name = res.get("config", {}).get("service_name", "")
        service_name = str(service_name).strip()
        # Extract service key: last dot-separated segment
        # Also handle ecr.api / ecr.dkr (two segments)
        svc_key = None
        for key in _VPC_ENDPOINT_SERVICE_MAP:
            if service_name.endswith('.' + key):
                svc_key = key
                break
        if not svc_key:
            parts = service_name.rsplit('.', 1)
            svc_key = parts[-1] if parts else ''

        target_type = _VPC_ENDPOINT_SERVICE_MAP.get(svc_key)
        if not target_type:
            continue

        for other in resources:
            if other["type"] == target_type:
                edge_key = (res["id"], other["id"])
                if edge_key not in seen:
                    seen.add(edge_key)
                    edges.append({
                        "from": res["id"],
                        "to": other["id"],
                        "via": "service_name",
                        "type": "traffic",
                        "label": svc_key,
                    })
