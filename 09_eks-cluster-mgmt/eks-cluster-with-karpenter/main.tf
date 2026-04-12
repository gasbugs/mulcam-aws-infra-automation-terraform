# source from: https://github.com/terraform-aws-modules/terraform-aws-eks/tree/master/examples/karpenter
resource "random_integer" "random_id" {
  max = 9999
  min = 1000
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = "karpenter-cluster-${random_integer.random_id.result}"
  tags = {
    Environment   = "prod"
    Team          = "platform-team"
    Application   = "web-app"
    CostCenter    = "CC-1234"
    ProvisionedBy = "Karpenter"
    Region        = "us-east-1"
  }
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
}

################################################################################
# EKS Module
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.8.0" # 버전 핀 추가 (재현 가능한 빌드를 위해 항상 버전 고정 권장)

  # v21: cluster_name → name, cluster_version → kubernetes_version
  name               = local.name
  kubernetes_version = "1.34"

  # Gives Terraform identity admin access to cluster which will
  # allow deploying resources (Karpenter) into the cluster
  enable_cluster_creator_admin_permissions = true
  # v21: cluster_endpoint_public_access → endpoint_public_access
  endpoint_public_access = true

  # DaemonSet 기반 애드온 — 노드 없이도 ACTIVE 전환 가능
  # coredns는 Deployment 기반이므로 노드 그룹 완료 후 aws_eks_addon 리소스로 별도 설치
  addons = {
    eks-pod-identity-agent = {} # Pod Identity 에이전트 (DaemonSet)
    kube-proxy             = {} # 노드 간 네트워크 규칙 관리 (DaemonSet)
    vpc-cni                = {} # 파드에 VPC IP 직접 할당 (DaemonSet)
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  # cluster_tags = merge(local.tags, {
  #   NOTE - only use this option if you are using "attach_cluster_primary_security_group"
  #   and you know what you're doing. In this case, you can remove the "node_security_group_tags" below.
  #  "karpenter.sh/discovery" = local.name
  # })

  node_security_group_tags = merge(local.tags, {
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    # (i.e. - at most, only one security group should have this tag in your account)
    "karpenter.sh/discovery" = "karpenter-cluster-${random_integer.random_id.result}"
  })

  tags = local.tags
}


################################################################################
# 노드 그룹 — EKS 모듈과 분리하여 별도 리소스로 생성
# CriticalAddonsOnly taint로 Karpenter/EKS 시스템 컴포넌트만 이 노드에서 실행
# Karpenter가 관리하는 애플리케이션 파드는 이 노드를 피해 Karpenter 프로비저닝 노드로 배치됨
################################################################################

# 노드 그룹용 IAM 역할 (EC2 인스턴스가 EKS 노드로 동작하기 위해 필요)
resource "aws_iam_role" "node_group" {
  name = "eks-node-group-role-${local.name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "node_group_worker" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_group_cni" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_group_ecr" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_group_ssm" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Karpenter 시스템 노드 그룹용 런치 템플릿 — IMDS hop limit 2 설정
# Karpenter 파드가 EC2 메타데이터 서비스(IMDS)를 통해 리전 정보를 가져오려면
# hop limit이 최소 2 이상이어야 함 (기본값 1이면 컨테이너에서 401 오류 발생)
resource "aws_launch_template" "karpenter_system" {
  name_prefix = "karpenter-system-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"        # IMDSv2 강제
    http_put_response_hop_limit = 2                 # 파드 → 노드 → IMDS 2홉 허용
  }
}

# Karpenter와 EKS Addon을 실행하기 위한 관리형 노드 그룹
resource "aws_eks_node_group" "karpenter" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "karpenter"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = module.vpc.private_subnets

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = ["m5.large"]

  launch_template {
    id      = aws_launch_template.karpenter_system.id
    version = aws_launch_template.karpenter_system.latest_version
  }

  scaling_config {
    min_size     = 2
    max_size     = 3
    desired_size = 2
  }

  taint {
    # EKS Addon과 Karpenter만 이 노드에서 실행되도록 taint 설정
    # 일반 애플리케이션 파드는 이 taint를 tolerate하지 않으면 Karpenter 프로비저닝 노드로 이동
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = {
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.node_group_worker,
    aws_iam_role_policy_attachment.node_group_cni,
    aws_iam_role_policy_attachment.node_group_ecr,
    aws_iam_role_policy_attachment.node_group_ssm,
    module.eks,
  ]
}

# -----------------------------------------------------------------------
# 노드 의존 애드온 — 노드그룹 완료 후 설치 (Deployment 기반 → 노드 필요)
# -----------------------------------------------------------------------

# 클러스터 내부 DNS (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "coredns" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.karpenter]
}

################################################################################
# Karpenter
################################################################################

module "karpenter" {
  source = "./.terraform/modules/eks/modules/karpenter"

  cluster_name                    = local.name
  create_pod_identity_association = true # Pod Identity를 통해 Karpenter ServiceAccount에 IAM 역할 연결

  # Karpenter가 프로비저닝하는 노드에 SSM 접근 허용 (디버깅 및 운영 편의)
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

# # 카펜터를 disable하는 예제 
# module "karpenter_disabled" {
#   source = "./.terraform/modules/eks/modules/karpenter"

#   create = false
# }

################################################################################
# Karpenter Helm chart & manifests
# Not required; just to demonstrate functionality of the sub-module
################################################################################

resource "helm_release" "karpenter" {
  namespace  = "kube-system"
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  #repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  #repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart   = "karpenter"
  version = "1.0.6"
  wait    = false

  values = [
    <<-EOT
    serviceAccount:
      name: ${module.karpenter.service_account}
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    EOT
  ]
}


# EKS에서 추천되는 AMI 검색 
data "aws_ssm_parameter" "eks_ami" {
  # kubernetes_version과 동일한 버전의 EKS 최적화 AMI ID를 SSM Parameter Store에서 동적으로 조회
  name = "/aws/service/eks/optimized-ami/1.34/amazon-linux-2023/x86_64/standard/recommended/image_id"
}

resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = templatefile("${path.module}/nodeclasses.yaml",
    {
      node_iam_role_name = module.karpenter.node_iam_role_name
      cluster_name       = module.eks.cluster_name
      ami_id             = data.aws_ssm_parameter.eks_ami.value
    }
  )

  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = file("${path.module}/nodepool.yaml")

  depends_on = [
    kubectl_manifest.karpenter_node_class
  ]
}


################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 52)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Tags subnets for Karpenter auto-discovery
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}
