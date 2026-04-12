# HashiCorp에서 제공하는 예시 코드, MPL-2.0 라이선스에 따라 배포됨
# 이 코드는 EKS 클러스터 + Cluster Autoscaler 구성을 포함

# AWS의 사용 가능한 가용 영역 중에서 Local Zone을 필터링
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  cluster_name = "education-eks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

# VPC 생성 모듈
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name = "education-vpc-${random_string.suffix.result}"

  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# EKS 클러스터 모듈
# addons 블록: DaemonSet 기반만 배치 (노드 없이도 ACTIVE 전환 가능)
# Deployment 기반(coredns, ebs-csi)은 노드그룹 완료 후 aws_eks_addon 리소스로 별도 설치
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.8.0"

  name               = local.cluster_name
  kubernetes_version = "1.34"

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  # DaemonSet 기반 애드온 — 노드 없이도 ACTIVE 전환 가능
  addons = {
    vpc-cni    = { update_policy = "OVERWRITE" } # 파드에 VPC IP 직접 할당 (DaemonSet)
    kube-proxy = { update_policy = "OVERWRITE" } # 노드 간 네트워크 규칙 관리 (DaemonSet)
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
}

# -----------------------------------------------------------------------
# ON_DEMAND 노드 그룹 — EKS 모듈과 분리하여 별도 모듈로 생성
# Cluster Autoscaler가 이 그룹을 스케일 아웃/인 대상으로 사용
# ASG 태그: Cluster Autoscaler가 auto-discovery로 대상 ASG를 찾는 데 필요
# kubernetes_version 명시 필수 — 미지정 시 최신 버전 AMI → 버전 불일치 오류
# -----------------------------------------------------------------------
module "eks_managed_node_group_on_demand" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "21.8"

  name                 = "on_demand"
  cluster_name         = module.eks.cluster_name
  cluster_service_cidr = module.eks.cluster_service_cidr
  subnet_ids           = module.vpc.private_subnets
  kubernetes_version   = "1.34" # 미지정 시 최신 버전 AMI 조회 → 클러스터 버전 불일치 오류

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = ["c5.large"]
  min_size       = 1
  max_size       = 4
  desired_size   = 1
  capacity_type  = "ON_DEMAND" # 온디맨드 인스턴스 (안정성 우선)

  labels = {
    type = "on-demand"
  }

  # Cluster Autoscaler auto-discovery를 위한 ASG 태그
  tags = {
    "k8s.io/cluster-autoscaler/enabled"                 = "true"
    "k8s.io/cluster-autoscaler/${module.eks.cluster_name}" = "owned"
  }
}

# SPOT 노드 그룹 — 비용 절감을 위한 스팟 인스턴스 노드 그룹
# Cluster Autoscaler가 이 그룹도 스케일 대상으로 관리
module "eks_managed_node_group_on_spot" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "21.8"

  name                 = "on_spot"
  cluster_name         = module.eks.cluster_name
  cluster_service_cidr = module.eks.cluster_service_cidr
  subnet_ids           = module.vpc.private_subnets
  kubernetes_version   = "1.34"

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = ["c5.large"]
  min_size       = 1
  max_size       = 4
  desired_size   = 1
  capacity_type  = "SPOT" # 스팟 인스턴스 (비용 절감, 인터럽트 가능)

  labels = {
    type = "on-spot"
  }

  # Cluster Autoscaler auto-discovery를 위한 ASG 태그
  tags = {
    "k8s.io/cluster-autoscaler/enabled"                 = "true"
    "k8s.io/cluster-autoscaler/${module.eks.cluster_name}" = "owned"
  }
}

# -----------------------------------------------------------------------
# 노드 의존 애드온 — 노드그룹 완료 후 설치 (Deployment 기반 → 노드 필요)
# -----------------------------------------------------------------------

# 클러스터 내부 DNS (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "coredns" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.eks_managed_node_group_on_demand, module.eks_managed_node_group_on_spot]
}

# EBS CSI 드라이버 (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = module.irsa-ebs-csi.iam_role_arn

  depends_on = [module.eks_managed_node_group_on_demand, module.eks_managed_node_group_on_spot]
}

# -----------------------------------------------------------------------
# IRSA — EBS CSI 드라이버용 IAM 역할
# -----------------------------------------------------------------------

data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.20"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}
