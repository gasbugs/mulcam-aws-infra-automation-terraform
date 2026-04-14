# HashiCorp에서 제공하는 예시 코드, MPL-2.0 라이선스에 따라 배포됨
# 이 코드는 EKS 클러스터를 프로비저닝하기 위한 기본 설정을 포함

# AWS의 사용 가능한 가용 영역 중에서 관리형 노드 그룹에 지원되지 않는 Local Zone을 필터링
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# 로컬 변수 선언. 클러스터 이름에 무작위 문자열을 추가하여 고유성을 보장
locals {
  cluster_name = "education-eks-${random_string.suffix.result}"
}

# 8자리 길이의 무작위 문자열을 생성하는 리소스. 특수 문자는 포함하지 않음
resource "random_string" "suffix" {
  length  = 8
  special = false
}

# VPC 생성 모듈
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name = "education-vpc-${random_string.suffix.result}" # VPC 이름에 랜덤 문자열을 붙여 중복 방지

  cidr = "10.100.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.100.101.0/24", "10.100.102.0/24", "10.100.103.0/24"]
  public_subnets  = ["10.100.1.0/24", "10.100.2.0/24", "10.100.3.0/24"]

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

# -----------------------------------------------------------------------
# EKS 클러스터 모듈 — 노드 그룹 없이 클러스터와 애드온만 생성
# 노드 그룹은 아래에서 별도 리소스로 선언하여 애드온 완료 후 생성 보장
# -----------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.8.0"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  # DaemonSet 기반 애드온 2종만 모듈 내에서 설치
  # vpc-cni, kube-proxy는 노드 없이도 ACTIVE 상태로 전환됨
  # coredns, aws-ebs-csi-driver는 Deployment 기반이라 노드가 있어야 ACTIVE 전환 가능
  # → 해당 둘은 아래에서 노드그룹 생성 이후에 별도 리소스로 설치
  addons = {
    vpc-cni = {
      resolve_conflicts_on_create = "OVERWRITE" # 노드가 Ready가 되려면 반드시 필요한 CNI 플러그인
      resolve_conflicts_on_update = "OVERWRITE"
    }
    kube-proxy = {
      resolve_conflicts_on_create = "OVERWRITE" # 노드 간 네트워크 규칙 관리
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # 점프 호스트 보안 그룹에서 443 포트 인바운드 허용
  security_group_additional_rules = {
    ingress_from_ssh_sg = {
      description              = "Allow HTTPS from SSH/EC2 security group"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      type                     = "ingress"
      source_security_group_id = aws_security_group.ssh_sg.id
    }
  }
}

# -----------------------------------------------------------------------
# 노드 그룹 — module.eks 완료(애드온 설치 포함) 후 생성
# vpc-cni가 설치된 상태에서 노드가 기동되므로 NotReady 루프 없음
# -----------------------------------------------------------------------

# 노드 그룹용 IAM 역할
resource "aws_iam_role" "node_group" {
  name = "eks-node-group-role-${local.cluster_name}" # 랜덤 문자열로 중복 방지

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
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

# 관리형 노드 그룹 — module.eks(애드온 포함) 완료 후 생성
resource "aws_eks_node_group" "one" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "node-group-1"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = module.vpc.private_subnets
  # 클러스터 버전과 항상 동일하게 유지 — 컨트롤 플레인 업그레이드 시 노드 그룹도 자동으로 따라감
  version         = module.eks.cluster_version

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = ["c5.large"]

  scaling_config {
    min_size     = 2
    max_size     = 10
    desired_size = 3
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_group_worker,
    aws_iam_role_policy_attachment.node_group_cni,
    aws_iam_role_policy_attachment.node_group_ecr,
    module.eks, # module.eks 전체(애드온 포함) 완료 후 노드 그룹 생성
  ]
}

# -----------------------------------------------------------------------
# 노드 의존 애드온 — 노드그룹 생성 완료 후 설치
# coredns, aws-ebs-csi-driver는 Deployment 기반이라 노드가 있어야 pod가
# 스케줄되고 ACTIVE 상태로 전환됨. 따라서 aws_eks_node_group 이후에 생성
# -----------------------------------------------------------------------

# 클러스터 내부 DNS 서비스 (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "coredns" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.one] # 노드그룹 완료 후 설치
}

# EBS 볼륨을 Kubernetes PersistentVolume으로 사용하기 위한 드라이버 (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = module.irsa-ebs-csi.iam_role_arn # IRSA로 연동된 역할의 ARN
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.one] # 노드그룹 완료 후 설치
}

# -----------------------------------------------------------------------
# EBS CSI 드라이버 IRSA 설정
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
