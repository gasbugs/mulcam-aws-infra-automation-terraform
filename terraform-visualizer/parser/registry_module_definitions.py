"""
Real resource expansions for well-known terraform-aws-modules registry modules.

Each entry defines the actual AWS resources that the module creates,
based on reading the module source code on GitHub.

Format per resource:
  {
    "type": "aws_resource_type",
    "name": "logical_name",      # used for display + edge resolution
    "condition": None | "var_flag",  # show if this flag is likely true
  }
"""

# terraform-aws-modules/vpc/aws
# Based on: https://github.com/terraform-aws-modules/terraform-aws-vpc
VPC_MODULE = {
    "match": ["terraform-aws-modules/vpc/aws"],
    "resources": [
        # Core VPC
        {"type": "aws_vpc",               "name": "this",          "group": "vpc"},
        # Internet Gateway
        {"type": "aws_internet_gateway",  "name": "this",          "group": "igw",
         "condition": "create_igw"},
        # Public subnets
        {"type": "aws_subnet",            "name": "public",        "group": "public",
         "label": "Public Subnets",       "multi": True},
        {"type": "aws_route_table",       "name": "public",        "group": "public",
         "label": "Public Route Table"},
        # Private subnets
        {"type": "aws_subnet",            "name": "private",       "group": "private",
         "label": "Private Subnets",      "multi": True},
        {"type": "aws_route_table",       "name": "private",       "group": "private",
         "label": "Private Route Table",  "multi": True},
        # NAT Gateway
        {"type": "aws_nat_gateway",       "name": "this",          "group": "public",
         "condition": "enable_nat_gateway"},
        {"type": "aws_eip",               "name": "nat",           "group": "public",
         "label": "NAT EIP",             "condition": "enable_nat_gateway"},
        # Database subnets
        {"type": "aws_subnet",            "name": "database",      "group": "database",
         "label": "DB Subnets",           "multi": True,
         "condition": "database_subnets"},
        {"type": "aws_db_subnet_group",   "name": "database",      "group": "database",
         "condition": "database_subnets"},
        # Elasticache subnets
        {"type": "aws_subnet",            "name": "elasticache",   "group": "database",
         "label": "Cache Subnets",        "multi": True,
         "condition": "elasticache_subnets"},
    ],
}

# terraform-aws-modules/eks/aws
# Based on: https://github.com/terraform-aws-modules/terraform-aws-eks
EKS_MODULE = {
    "match": ["terraform-aws-modules/eks/aws"],
    "resources": [
        # Control plane
        {"type": "aws_eks_cluster",               "name": "this",            "group": "cluster"},
        {"type": "aws_cloudwatch_log_group",      "name": "this",            "group": "monitoring"},
        # Cluster IAM
        {"type": "aws_iam_role",                  "name": "this",            "group": "iam",
         "label": "EKS Cluster Role"},
        {"type": "aws_iam_role_policy_attachment", "name": "this",           "group": "iam",
         "label": "Cluster IAM Policies",         "multi": True},
        # Cluster security group
        {"type": "aws_security_group",            "name": "cluster",         "group": "security",
         "label": "Cluster SG"},
        # Node group (managed)
        {"type": "aws_eks_node_group",            "name": "this",            "group": "nodegroup",
         "label": "Managed Node Group"},
        {"type": "aws_iam_role",                  "name": "node_group",      "group": "iam",
         "label": "Node Group Role"},
        {"type": "aws_launch_template",           "name": "this",            "group": "nodegroup",
         "label": "Node Launch Template"},
        # IRSA / OIDC
        {"type": "aws_iam_openid_connect_provider", "name": "oidc_provider", "group": "iam",
         "label": "OIDC Provider",                "condition": "enable_irsa"},
        # EKS Addons
        {"type": "aws_eks_addon",                 "name": "coredns",         "group": "addon",
         "label": "CoreDNS Addon"},
        {"type": "aws_eks_addon",                 "name": "kube_proxy",      "group": "addon",
         "label": "kube-proxy Addon"},
        {"type": "aws_eks_addon",                 "name": "vpc_cni",         "group": "addon",
         "label": "VPC CNI Addon"},
    ],
}

# terraform-aws-modules/eks/aws//modules/eks-managed-node-group
EKS_NODE_GROUP_MODULE = {
    "match": ["eks/aws//modules/eks-managed-node-group", "eks//modules/eks-managed-node-group"],
    "resources": [
        {"type": "aws_eks_node_group",            "name": "this",            "group": "nodegroup"},
        {"type": "aws_iam_role",                  "name": "this",            "group": "iam",
         "label": "Node Group Role"},
        {"type": "aws_iam_role_policy_attachment", "name": "this",           "group": "iam",
         "label": "Node IAM Policies",            "multi": True},
        {"type": "aws_launch_template",           "name": "this",            "group": "nodegroup"},
    ],
}

# terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc
IAM_OIDC_MODULE = {
    "match": ["iam/aws//modules/iam-assumable-role-with-oidc",
              "iam-assumable-role-with-oidc"],
    "resources": [
        {"type": "aws_iam_role",                  "name": "this",            "group": "iam"},
        {"type": "aws_iam_role_policy_attachment", "name": "this",           "group": "iam",
         "label": "OIDC Role Policies",           "multi": True},
    ],
}

# terraform-aws-modules/s3-bucket/aws
S3_BUCKET_MODULE = {
    "match": ["terraform-aws-modules/s3-bucket/aws"],
    "resources": [
        {"type": "aws_s3_bucket",                         "name": "this",   "group": "storage"},
        {"type": "aws_s3_bucket_versioning",              "name": "this",   "group": "storage"},
        {"type": "aws_s3_bucket_public_access_block",     "name": "this",   "group": "storage"},
        {"type": "aws_s3_bucket_server_side_encryption_configuration",
                                                          "name": "this",   "group": "storage"},
        {"type": "aws_s3_bucket_policy",                  "name": "this",   "group": "storage"},
    ],
}

# terraform-aws-modules/ecr/aws
ECR_MODULE = {
    "match": ["terraform-aws-modules/ecr/aws"],
    "resources": [
        {"type": "aws_ecr_repository",       "name": "this",    "group": "container"},
        {"type": "aws_ecr_lifecycle_policy",  "name": "this",    "group": "container"},
    ],
}

# terraform-aws-modules/ec2-instance/aws
EC2_INSTANCE_MODULE = {
    "match": ["terraform-aws-modules/ec2-instance/aws"],
    "resources": [
        {"type": "aws_instance",             "name": "this",    "group": "compute"},
        {"type": "aws_eip",                  "name": "this",    "group": "compute",
         "condition": "create_eip"},
    ],
}

# karpenter (from eks module)
KARPENTER_MODULE = {
    "match": ["karpenter", "modules/karpenter"],
    "resources": [
        {"type": "aws_iam_role",                   "name": "karpenter",        "group": "iam",
         "label": "Karpenter Controller Role"},
        {"type": "aws_iam_role_policy_attachment",  "name": "karpenter",        "group": "iam",
         "multi": True},
        {"type": "aws_sqs_queue",                  "name": "karpenter",        "group": "serverless",
         "label": "Karpenter Interruption Queue"},
        {"type": "aws_cloudwatch_event_rule",       "name": "karpenter",        "group": "monitoring",
         "label": "Spot Interruption Rule"},
    ],
}

# terraform-aws-modules/vpc/aws//modules/vpc-endpoints
VPC_ENDPOINTS_MODULE = {
    "match": ["vpc/aws//modules/vpc-endpoints", "vpc-endpoints"],
    "resources": [
        {"type": "aws_vpc_endpoint",  "name": "this",  "group": "networking",
         "label": "VPC Endpoints",   "multi": True},
        {"type": "aws_security_group", "name": "this", "group": "security",
         "label": "Endpoint SG"},
    ],
}


# Registry of all known module definitions
ALL_MODULES = [
    VPC_MODULE,
    EKS_MODULE,
    EKS_NODE_GROUP_MODULE,
    IAM_OIDC_MODULE,
    S3_BUCKET_MODULE,
    ECR_MODULE,
    EC2_INSTANCE_MODULE,
    KARPENTER_MODULE,
    VPC_ENDPOINTS_MODULE,
]


def find_module_definition(source: str):
    """Find a module definition that matches the given source string."""
    for mod_def in ALL_MODULES:
        for pattern in mod_def["match"]:
            if pattern in source:
                return mod_def
    return None
