# HashiCorp에서 제공하는 예시 코드, MPL-2.0 라이선스에 따라 배포됨
# 이 코드는 EKS 클러스터 + ON_DEMAND / SPOT 노드 그룹 혼합 구성을 포함

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
  kubernetes_version = var.kubernetes_version

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
# 노드 의존 애드온 — 노드그룹 완료 후 설치 (Deployment 기반 → 노드 필요)
# ON_DEMAND / SPOT 노드 그룹은 spot_node_group.tf 에서 정의
# -----------------------------------------------------------------------

# 클러스터 내부 DNS (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "coredns" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"

  # ON_DEMAND 노드가 있어야 coredns Deployment가 스케줄됨
  depends_on = [aws_eks_node_group.on_demand_nodegroup, aws_eks_node_group.spot_nodegroup]
}

# EBS CSI 드라이버 (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = module.irsa-ebs-csi.iam_role_arn

  depends_on = [aws_eks_node_group.on_demand_nodegroup, aws_eks_node_group.spot_nodegroup]
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
