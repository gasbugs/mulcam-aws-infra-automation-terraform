# HashiCorp에서 제공하는 예시 코드, MPL-2.0 라이선스에 따라 배포됨
# 이 코드는 EKS 클러스터를 프로비저닝하기 위한 기본 설정을 포함
# 원본은 HashiCorp GitHub에서 확인 가능: https://github.com/hashicorp/learn-terraform-provision-eks-cluster/blob/main/main.tf

# AWS의 사용 가능한 가용 영역 중에서 관리형 노드 그룹에 지원되지 않는 Local Zone을 필터링
# 'opt-in-not-required' 상태인 가용 영역만 선택하여 사용
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"         # 필터링할 항목의 이름
    values = ["opt-in-not-required"] # 필터 조건
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

# VPC 생성 모듈을 정의. Terraform의 VPC 모듈을 사용해 VPC를 프로비저닝
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws" # VPC 모듈의 소스 경로
  version = "6.5.0"                         # VPC 모듈의 버전

  name = "education-vpc-${random_string.suffix.result}" # VPC 이름에 랜덤 문자열을 붙여 중복 방지

  # VPC의 CIDR 블록을 10.0.0.0/16으로 설정
  cidr = "10.0.0.0/16"
  # 필터링된 가용 영역 중 상위 3개를 선택
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # 사설 서브넷의 CIDR 블록 정의
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  # 공용 서브넷의 CIDR 블록 정의
  public_subnets = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  # NAT 게이트웨이를 활성화하고, 단일 NAT 게이트웨이를 사용
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true # DNS 호스트 이름을 활성화

  # 공용 서브넷의 태그. ELB 역할을 부여
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  # 사설 서브넷의 태그. 내부 ELB 역할을 부여
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# -----------------------------------------------------------------------
# EKS 클러스터 모듈 — 노드 그룹 없이 클러스터와 DaemonSet 기반 애드온만 생성
# vpc-cni, kube-proxy는 노드 없이도 ACTIVE 전환 가능
# coredns, aws-ebs-csi-driver는 Deployment 기반이므로 노드 생성 이후에 별도 설치
# -----------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws" # EKS 모듈의 소스 경로
  version = "21.8.0"                        # EKS 모듈의 버전

  # 클러스터 이름과 버전 설정
  name               = local.cluster_name # 로컬에서 정의한 클러스터 이름 사용
  kubernetes_version = "1.35"             # EKS 클러스터의 버전 설정

  endpoint_public_access                   = true # 클러스터의 퍼블릭 엔드포인트 접근을 허용
  enable_cluster_creator_admin_permissions = true # 클러스터 생성자에게 관리 권한 부여

  # DaemonSet 기반 애드온만 모듈 내에서 설치 (노드 없이도 ACTIVE 전환)
  addons = {
    vpc-cni = {
      resolve_conflicts_on_create = "OVERWRITE" # 노드 네트워크에 반드시 필요한 CNI 플러그인
      resolve_conflicts_on_update = "OVERWRITE"
    }
    kube-proxy = {
      resolve_conflicts_on_create = "OVERWRITE" # 노드 간 네트워크 규칙 관리
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }

  vpc_id     = module.vpc.vpc_id          # 생성된 VPC ID 사용
  subnet_ids = module.vpc.private_subnets # 생성된 사설 서브넷 사용
}

# -----------------------------------------------------------------------
# 노드 그룹용 IAM 역할 — module.eks 완료 후 노드 그룹 생성
# -----------------------------------------------------------------------

# 노드 그룹용 IAM 역할 (EC2 인스턴스가 EKS 노드로 동작하기 위해 필요)
resource "aws_iam_role" "node_group" {
  name = "eks-node-group-role-${local.cluster_name}"

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

# 첫 번째 관리형 노드 그룹 — module.eks 완료(DaemonSet 애드온 포함) 후 생성
resource "aws_eks_node_group" "one" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "node-group-1"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = module.vpc.private_subnets

  ami_type       = "AL2023_x86_64_STANDARD" # Amazon Linux 2023 사용
  instance_types = ["t3.small"]             # 노드 인스턴스 유형

  scaling_config {
    min_size     = 1 # 최소 노드 수
    max_size     = 3 # 최대 노드 수
    desired_size = 2 # 원하는 노드 수
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_group_worker,
    aws_iam_role_policy_attachment.node_group_cni,
    aws_iam_role_policy_attachment.node_group_ecr,
    module.eks,
  ]
}

# 두 번째 관리형 노드 그룹
resource "aws_eks_node_group" "two" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "node-group-2"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = module.vpc.private_subnets

  instance_types = ["t3.small"] # 노드 인스턴스 유형

  scaling_config {
    min_size     = 1 # 최소 노드 수
    max_size     = 2 # 최대 노드 수
    desired_size = 1 # 원하는 노드 수
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_group_worker,
    aws_iam_role_policy_attachment.node_group_cni,
    aws_iam_role_policy_attachment.node_group_ecr,
    module.eks,
  ]
}

# -----------------------------------------------------------------------
# 노드 의존 애드온 — 노드그룹 생성 완료 후 설치
# coredns, aws-ebs-csi-driver는 Deployment 기반으로 노드가 있어야 ACTIVE 전환
# -----------------------------------------------------------------------

# 클러스터 내부 DNS 서비스 (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "coredns" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.one]
}

# EBS 볼륨을 Kubernetes PV로 사용하기 위한 드라이버 (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = module.irsa-ebs-csi.iam_role_arn # IRSA로 연동된 역할의 ARN 사용
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.one]
}

# EBS CSI 드라이버 정책을 불러옴
# EKS 클러스터에서 사용될 EBS CSI 드라이버 IAM 정책 정의
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# IRSA(Identity and Access Management Roles for Service Accounts) 모듈을 정의
# EKS 클러스터에 EBS CSI 드라이버와 연동할 역할을 생성
module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc" # IAM 모듈의 경로
  version = "4.20"                                                                # 모듈 버전

  create_role                   = true                                                        # 역할을 생성하도록 설정
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"          # 역할 이름 설정
  provider_url                  = module.eks.oidc_provider                                    # EKS OIDC 프로바이더 URL
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]                    # EBS CSI 드라이버 정책 ARN
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"] # OIDC 주체 설정
}
