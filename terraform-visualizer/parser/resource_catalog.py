"""AWS resource type to category/icon mapping."""

CATEGORIES = {
    "networking": {
        "label": "Networking",
        "zone": "vpc",
        "color": "#8C4FFF",
        "resources": [
            "aws_vpc", "aws_subnet", "aws_internet_gateway",
            "aws_nat_gateway", "aws_route_table", "aws_route_table_association",
            "aws_route", "aws_vpc_endpoint", "aws_network_interface",
            "aws_eip", "aws_vpc_peering_connection",
            "aws_default_route_table", "aws_default_subnet", "aws_default_vpc",
        ],
    },
    "security": {
        "label": "Security",
        "zone": "cross",
        "color": "#DD344C",
        "resources": [
            "aws_security_group", "aws_security_group_rule",
            "aws_vpc_security_group_ingress_rule",
            "aws_vpc_security_group_egress_rule",
            "aws_network_acl", "aws_network_acl_rule",
            "aws_wafv2_web_acl", "aws_wafv2_web_acl_association",
            "aws_wafv2_ip_set", "aws_wafv2_rule_group",
        ],
    },
    "compute": {
        "label": "Compute",
        "zone": "private",
        "color": "#ED7100",
        "resources": [
            "aws_instance", "aws_launch_template", "aws_key_pair",
            "aws_autoscaling_group", "aws_autoscaling_policy",
            "aws_autoscaling_attachment", "aws_placement_group",
            "aws_ami", "aws_ami_from_instance",
        ],
    },
    "loadbalancing": {
        "label": "Load Balancing",
        "zone": "public",
        "color": "#8C4FFF",
        "resources": [
            "aws_lb", "aws_alb", "aws_lb_listener", "aws_alb_listener",
            "aws_lb_target_group", "aws_alb_target_group",
            "aws_lb_target_group_attachment", "aws_lb_listener_rule",
        ],
    },
    "database": {
        "label": "Database",
        "zone": "database",
        "color": "#3B48CC",
        "resources": [
            "aws_db_instance", "aws_db_subnet_group", "aws_db_parameter_group",
            "aws_db_option_group",
            "aws_rds_cluster", "aws_rds_cluster_instance",
            "aws_rds_cluster_parameter_group",
            "aws_dynamodb_table", "aws_dynamodb_table_item",
            "aws_elasticache_replication_group", "aws_elasticache_cluster",
            "aws_elasticache_subnet_group", "aws_elasticache_parameter_group",
            "aws_elasticache_serverless_cache",
        ],
    },
    "storage": {
        "label": "Storage",
        "zone": "external",
        "color": "#3F8624",
        "resources": [
            "aws_s3_bucket", "aws_s3_object", "aws_s3_bucket_policy",
            "aws_s3_bucket_website_configuration",
            "aws_s3_bucket_public_access_block",
            "aws_s3_bucket_ownership_controls",
            "aws_s3_bucket_acl", "aws_s3_bucket_versioning",
            "aws_s3_bucket_server_side_encryption_configuration",
            "aws_s3_bucket_cors_configuration",
            "aws_efs_file_system", "aws_efs_mount_target",
            "aws_efs_access_point",
            "aws_ebs_volume", "aws_volume_attachment",
            "aws_backup_plan", "aws_backup_vault", "aws_backup_selection",
        ],
    },
    "cdn": {
        "label": "CDN & DNS",
        "zone": "external",
        "color": "#8C4FFF",
        "resources": [
            "aws_cloudfront_distribution",
            "aws_cloudfront_origin_access_control",
            "aws_cloudfront_origin_access_identity",
            "aws_cloudfront_cache_policy",
            "aws_route53_zone", "aws_route53_record",
            "aws_acm_certificate", "aws_acm_certificate_validation",
        ],
    },
    "serverless": {
        "label": "Serverless",
        "zone": "private",
        "color": "#ED7100",
        "resources": [
            "aws_lambda_function", "aws_lambda_permission",
            "aws_lambda_event_source_mapping", "aws_lambda_layer_version",
            "aws_apigatewayv2_api", "aws_apigatewayv2_stage",
            "aws_apigatewayv2_integration", "aws_apigatewayv2_route",
            "aws_api_gateway_rest_api", "aws_api_gateway_resource",
            "aws_api_gateway_method", "aws_api_gateway_integration",
            "aws_api_gateway_deployment", "aws_api_gateway_stage",
            "aws_sqs_queue", "aws_sns_topic", "aws_sns_topic_subscription",
        ],
    },
    "iam": {
        "label": "IAM & Security",
        "zone": "side",
        "color": "#DD344C",
        "resources": [
            "aws_iam_role", "aws_iam_policy", "aws_iam_role_policy_attachment",
            "aws_iam_role_policy", "aws_iam_instance_profile",
            "aws_iam_user", "aws_iam_user_policy_attachment",
            "aws_iam_group", "aws_iam_group_policy_attachment",
            "aws_iam_policy_document", "aws_iam_openid_connect_provider",
            "aws_iam_service_linked_role",
            "aws_kms_key", "aws_kms_alias",
            "aws_secretsmanager_secret", "aws_secretsmanager_secret_version",
        ],
    },
    "container": {
        "label": "Containers",
        "zone": "private",
        "color": "#ED7100",
        "resources": [
            "aws_ecs_cluster", "aws_ecs_service", "aws_ecs_task_definition",
            "aws_ecs_cluster_capacity_providers",
            "aws_ecr_repository", "aws_ecr_lifecycle_policy",
            "aws_ecr_pull_through_cache_rule",
            "aws_eks_cluster", "aws_eks_node_group", "aws_eks_addon",
            "aws_eks_fargate_profile", "aws_eks_identity_provider_config",
            "aws_eks_access_entry", "aws_eks_access_policy_association",
        ],
    },
    "cicd": {
        "label": "CI/CD",
        "zone": "external",
        "color": "#3B48CC",
        "resources": [
            "aws_codebuild_project", "aws_codepipeline",
            "aws_codecommit_repository",
            "aws_codestarconnections_connection",
        ],
    },
    "monitoring": {
        "label": "Monitoring",
        "zone": "side",
        "color": "#E7157B",
        "resources": [
            "aws_cloudwatch_log_group", "aws_cloudwatch_metric_alarm",
            "aws_cloudwatch_dashboard",
        ],
    },
}

# Build reverse lookup: resource_type -> category_key
RESOURCE_TO_CATEGORY = {}
for cat_key, cat_info in CATEGORIES.items():
    for res_type in cat_info["resources"]:
        RESOURCE_TO_CATEGORY[res_type] = cat_key

# Icon name mapping (resource type -> icon key used in frontend)
RESOURCE_ICON_MAP = {
    "aws_vpc": "vpc",
    "aws_subnet": "subnet",
    "aws_internet_gateway": "igw",
    "aws_nat_gateway": "nat",
    "aws_route_table": "route_table",
    "aws_eip": "eip",
    "aws_security_group": "security_group",
    "aws_vpc_security_group_ingress_rule": "security_group",
    "aws_vpc_security_group_egress_rule": "security_group",
    "aws_wafv2_web_acl": "waf",
    "aws_instance": "ec2",
    "aws_launch_template": "ec2",
    "aws_key_pair": "key_pair",
    "aws_autoscaling_group": "asg",
    "aws_autoscaling_policy": "asg",
    "aws_lb": "alb",
    "aws_alb": "alb",
    "aws_lb_listener": "alb",
    "aws_lb_target_group": "alb",
    "aws_db_instance": "rds",
    "aws_db_subnet_group": "rds",
    "aws_rds_cluster": "aurora",
    "aws_rds_cluster_instance": "aurora",
    "aws_dynamodb_table": "dynamodb",
    "aws_elasticache_replication_group": "elasticache",
    "aws_elasticache_cluster": "elasticache",
    "aws_elasticache_serverless_cache": "elasticache",
    "aws_s3_bucket": "s3",
    "aws_s3_object": "s3",
    "aws_efs_file_system": "efs",
    "aws_efs_mount_target": "efs",
    "aws_ebs_volume": "ebs",
    "aws_cloudfront_distribution": "cloudfront",
    "aws_route53_zone": "route53",
    "aws_route53_record": "route53",
    "aws_acm_certificate": "acm",
    "aws_lambda_function": "lambda_fn",
    "aws_apigatewayv2_api": "api_gw",
    "aws_api_gateway_rest_api": "api_gw",
    "aws_sqs_queue": "sqs",
    "aws_sns_topic": "sns",
    "aws_iam_role": "iam_role",
    "aws_iam_policy": "iam_policy",
    "aws_iam_user": "iam_user",
    "aws_iam_instance_profile": "iam_role",
    "aws_kms_key": "kms",
    "aws_secretsmanager_secret": "secrets_manager",
    "aws_ecs_cluster": "ecs",
    "aws_ecs_service": "ecs",
    "aws_ecs_task_definition": "ecs",
    "aws_ecr_repository": "ecr",
    "aws_eks_cluster": "eks",
    "aws_eks_node_group": "eks",
    "aws_eks_addon": "eks",
    "aws_eks_fargate_profile": "fargate",
    "aws_codebuild_project": "codebuild",
    "aws_codepipeline": "codepipeline",
    "aws_codecommit_repository": "codecommit",
    "aws_cloudwatch_log_group": "cloudwatch",
    "aws_cloudwatch_metric_alarm": "cloudwatch",
    "aws_backup_plan": "backup",
    "aws_backup_vault": "backup",
    "aws_vpc_endpoint": "vpc_endpoint",
    "aws_cloudfront_origin_access_control": "cloudfront",
    "helm_release": "helm",
    "kubernetes_service_v1": "kubernetes",
    "kubernetes_deployment_v1": "kubernetes",
    "kubernetes_ingress_v1": "kubernetes",
}

# Well-known registry module representations
REGISTRY_MODULE_STUBS = {
    "terraform-aws-modules/vpc/aws": {
        "icon": "vpc",
        "category": "networking",
        "label": "VPC Module",
        "sub_resources": ["VPC", "Subnets", "IGW", "NAT GW", "Route Tables"],
    },
    "terraform-aws-modules/eks/aws": {
        "icon": "eks",
        "category": "container",
        "label": "EKS Module",
        "sub_resources": ["EKS Cluster", "Node Groups", "IRSA"],
    },
    "terraform-aws-modules/iam/aws": {
        "icon": "iam_role",
        "category": "iam",
        "label": "IAM Module",
        "sub_resources": ["Roles", "Policies"],
    },
}


# ===== Plumbing / hidden resource types =====
# These are parsed for edge resolution but NOT rendered as visual nodes.
HIDDEN_TYPES = {
    # VPC plumbing
    "aws_route_table", "aws_route_table_association", "aws_route",
    "aws_network_acl", "aws_network_acl_rule",
    "aws_vpc_block_public_access_options", "aws_vpc_block_public_access_exclusion",
    "aws_vpc_dhcp_options", "aws_vpc_dhcp_options_association",
    "aws_vpc_ipv4_cidr_block_association",
    "aws_egress_only_internet_gateway",
    "aws_flow_log",
    # VPN / advanced networking (too detailed)
    "aws_vpn_gateway", "aws_vpn_gateway_attachment",
    "aws_vpn_gateway_route_propagation", "aws_customer_gateway",
    # AWS default resources (always exist, not user-defined)
    "aws_default_vpc", "aws_default_subnet",
    "aws_default_route_table", "aws_default_network_acl",
    "aws_default_security_group",
    # Subnet groups (implicit when DB resources exist)
    "aws_db_subnet_group", "aws_elasticache_subnet_group",
    "aws_redshift_subnet_group",
    # IAM plumbing (role/policy themselves are now shown for permission edges)
    "aws_iam_role_policy_attachment", "aws_iam_role_policy",
    "aws_iam_instance_profile",
    "aws_iam_openid_connect_provider",
    "aws_iam_user_policy", "aws_iam_service_specific_credential",
    "aws_iam_access_key", "aws_iam_group", "aws_iam_group_membership",
    "aws_iam_group_policy_attachment",
    # LB plumbing
    "aws_lb_target_group_attachment",
    # ASG plumbing
    "aws_autoscaling_policy", "aws_autoscaling_attachment",
    "aws_autoscaling_schedule",
    # EBS is shown as a badge inside the attached EC2 instance, not as a standalone node
    "aws_ebs_volume", "aws_volume_attachment",
    # Security group is shown as a badge on the attached resource, not as a standalone node
    "aws_security_group",
    "aws_security_group_rule",
    "aws_vpc_security_group_ingress_rule",
    "aws_vpc_security_group_egress_rule",
    # EFS plumbing (filesystem itself is shown; mount target is plumbing)
    "aws_efs_mount_target", "aws_efs_access_point",
    # S3 config sub-resources (bucket itself is shown)
    "aws_s3_object", "aws_s3_bucket_policy",
    "aws_s3_bucket_public_access_block", "aws_s3_bucket_ownership_controls",
    "aws_s3_bucket_acl", "aws_s3_bucket_versioning",
    "aws_s3_bucket_server_side_encryption_configuration",
    "aws_s3_bucket_cors_configuration", "aws_s3_bucket_website_configuration",
    # LB listener rule (listener/target group are now visible for traffic edges)
    "aws_lb_listener_rule",
    # EKS configuration plumbing (cluster/nodegroup are shown; config detail hidden)
    "aws_eks_addon", "aws_eks_access_entry", "aws_eks_access_policy_association",
    "aws_eks_identity_provider_config",
    # KMS plumbing
    "aws_kms_grant",
    # Kubernetes plumbing (service_v1/helm_release are shown)
    "kubernetes_secret_v1", "kubernetes_namespace_v1",
    "kubernetes_service_account_v1", "kubernetes_config_map_v1",
    "kubernetes_role_v1", "kubernetes_role_binding_v1",
    "kubernetes_cluster_role_v1", "kubernetes_cluster_role_binding_v1",
    # EventBridge / CloudWatch Events plumbing
    "aws_cloudwatch_event_rule", "aws_cloudwatch_event_target",
    "aws_cloudwatch_event_bus", "aws_cloudwatch_metric_alarm",
    # EC2 / ASG config detail
    "aws_ec2_tag", "aws_placement_group",
    # CloudFront config sub-resources
    "aws_cloudfront_origin_access_identity",
    # CodePipeline / CodeBuild config detail
    "aws_codestarconnections_connection",
    "aws_codebuild_source_credential",
    # Misc meta-resources
    "aws_vpc_endpoint_route_table_association",
    "aws_key_pair",
    "terraform_data", "null_resource",
    "random_password", "random_string", "random_id", "random_integer",
    "local_file", "local_sensitive_file",
    "tls_private_key", "tls_cert_request", "tls_self_signed_cert",
    "time_sleep", "time_rotating", "time_static",
}

# Resources that serve as visual containers (VPC, subnet zones) — not leaf nodes
STRUCTURAL_TYPES = {
    "aws_vpc",
    "aws_subnet",
}


def get_category(resource_type):
    return RESOURCE_TO_CATEGORY.get(resource_type, "other")


def get_icon(resource_type):
    return RESOURCE_ICON_MAP.get(resource_type, "generic")


def get_zone(resource_type):
    cat = get_category(resource_type)
    if cat == "other":
        return "private"
    return CATEGORIES[cat]["zone"]


def get_color(resource_type):
    cat = get_category(resource_type)
    if cat == "other":
        return "#888888"
    return CATEGORIES[cat]["color"]


def is_hidden(resource_type):
    return resource_type in HIDDEN_TYPES


def is_structural(resource_type):
    return resource_type in STRUCTURAL_TYPES
