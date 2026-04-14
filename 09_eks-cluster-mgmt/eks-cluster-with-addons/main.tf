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

# 8자리 길이의 무작위 문자열을 생성하는 리소스
resource "random_string" "suffix" {
  length  = 8
  special = false
}

# VPC 생성 모듈을 정의
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name = "education-vpc-${random_string.suffix.result}" # VPC 이름에 랜덤 문자열을 붙여 중복 방지

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

# EKS 클러스터 생성 모듈을 정의
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.8.0"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  # DaemonSet 기반 애드온만 모듈 내에서 설치 (노드 없이도 ACTIVE 전환 가능)
  # coredns, aws-ebs-csi-driver, aws-efs-csi-driver는 Deployment 기반이므로
  # 노드그룹 생성 이후에 별도 aws_eks_addon 리소스로 설치
  addons = {
    # Amazon VPC CNI (DaemonSet 기반 → 노드 없이도 ACTIVE)
    vpc-cni = {
      update_policy            = "OVERWRITE"
      service_account_role_arn = module.irsa_vpc_cni.iam_role_arn # IRSA 역할 추가
    }

    # Kube-proxy (DaemonSet 기반 → 노드 없이도 ACTIVE)
    kube-proxy = {
      update_policy = "OVERWRITE"
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
}

# -----------------------------------------------------------------------
# 노드 의존 애드온 — 노드그룹 생성 완료 후 설치
# Deployment 기반이라 노드가 있어야 pod가 스케줄되어 ACTIVE 전환
# -----------------------------------------------------------------------

# 클러스터 내부 DNS 서비스 (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "coredns" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "coredns"
  resolve_conflicts_on_update = "OVERWRITE" # 충돌 시 강제 덮어쓰기

  depends_on = [module.eks_managed_node_groups]
}

# EBS 볼륨을 Kubernetes PV로 사용하기 위한 드라이버 (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_update = "OVERWRITE" # 충돌 시 강제 덮어쓰기
  service_account_role_arn    = module.irsa-ebs-csi.iam_role_arn # IRSA 역할 추가

  depends_on = [module.eks_managed_node_groups]
}

# EFS 볼륨을 Kubernetes PV로 사용하기 위한 드라이버 (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "efs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-efs-csi-driver"
  resolve_conflicts_on_update = "OVERWRITE" # 충돌 시 강제 덮어쓰기
  service_account_role_arn    = module.irsa-efs-csi.iam_role_arn # IRSA 역할 추가

  depends_on = [module.eks_managed_node_groups]
}

# CloudWatch 옵저버빌리티 애드온 — 컨테이너 로그·메트릭·트레이스를 CloudWatch로 전송
# (Deployment/DaemonSet 기반 → 노드 필요)
resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "amazon-cloudwatch-observability"
  resolve_conflicts_on_update = "OVERWRITE"                                      # 충돌 시 강제 덮어쓰기
  service_account_role_arn    = module.irsa-cloudwatch.iam_role_arn              # IRSA 역할 추가

  depends_on = [module.eks_managed_node_groups]
}

module "eks_managed_node_groups" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group" # EKS 관리형 노드 그룹 모듈 경로
  version = "21.8"                                                          # 모듈 버전

  name                 = "on_demand"                     # 첫 번째 노드 그룹 이름
  cluster_name         = module.eks.cluster_name         # EKS 클러스터 이름
  kubernetes_version   = module.eks.cluster_version      # 클러스터와 노드 그룹 버전 일치 (업그레이드 시 컨트롤 플레인 버전 자동 추적)
  cluster_service_cidr = module.eks.cluster_service_cidr # 클러스터 서비스 CIDR
  subnet_ids           = module.vpc.private_subnets      # 사설 서브넷 ID

  ami_type       = "AL2023_x86_64_STANDARD" # Amazon Linux 2023 사용
  instance_types = ["c5.large"]             # 노드 인스턴스 유형
  min_size       = 1                        # 최소 노드 수
  max_size       = 3                        # 최대 노드 수
  desired_size   = 2                        # 원하는 노드 수
}


# IRSA 모듈 정의 (EBS CSI 드라이버)
module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.20"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

module "irsa-efs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.20"

  create_role                   = true
  role_name                     = "AmazonEKSEFSRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = ["arn:aws:iam::aws:policy/AmazonElasticFileSystemFullAccess"] # EFS에 대한 전체 액세스 권한 부여
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:efs-csi-controller-sa"]
}

# CloudWatch 에이전트가 메트릭·로그를 CloudWatch로 전송하기 위한 IAM 역할 (IRSA)
module "irsa-cloudwatch" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.20"

  create_role  = true
  role_name    = "AmazonEKSCloudWatchRole-${module.eks.cluster_name}"
  provider_url = module.eks.oidc_provider
  role_policy_arns = [
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy", # CloudWatch 메트릭·로그 전송
    "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess",      # X-Ray 트레이스 전송 (선택)
  ]
  # amazon-cloudwatch 네임스페이스의 cloudwatch-agent 서비스어카운트에 역할 허용
  oidc_fully_qualified_subjects = ["system:serviceaccount:amazon-cloudwatch:cloudwatch-agent"]
}

module "irsa_vpc_cni" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.20"

  create_role                   = true                                             # 새로운 IAM 역할을 생성
  role_name                     = "AmazonEKSVPCCNIRole-${module.eks.cluster_name}" # 역할 이름 설정
  provider_url                  = module.eks.oidc_provider                         # EKS 클러스터의 OIDC 프로바이더 설정
  role_policy_arns              = ["arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"] # AWS VPC CNI 플러그인에 필요한 IAM 정책을 연결
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:aws-node"]   # 해당 역할이 적용될 Kubernetes ServiceAccount를 명시
}

# EFS 파일 시스템 생성
# creation_token은 리전 내 고유해야 하므로 랜덤 문자열로 중복 방지
resource "aws_efs_file_system" "example" {
  creation_token = "efs-example-${random_string.suffix.result}"
  encrypted      = true # 암호화 여부
  tags = {
    Name = "example-efs-${random_string.suffix.result}"
  }
}

# 출력할 EFS 파일 시스템 ID
output "efs_file_system_id" {
  value = aws_efs_file_system.example.id
}


# EFS 보안 그룹 생성
# 이름에 랜덤 문자열을 붙여 재배포 시 이름 충돌을 방지
resource "aws_security_group" "my_efs_sg" {
  name        = "efs-sg-${random_string.suffix.result}"
  description = "Allow NFS traffic for EFS"
  vpc_id      = module.vpc.vpc_id # VPC ID를 VPC 모듈에서 가져옴

  # 인바운드 규칙: NFS 트래픽 (포트 2049) 허용
  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # VPC 내 트래픽을 허용 (필요시 변경)
  }

  # 아웃바운드 규칙: 모든 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "efs-sg-${random_string.suffix.result}"
  }
}


# 각 서브넷(가용 영역)에 대해 EFS 마운트 타겟 생성
# toset() 대신 인덱스를 키로 사용하는 map을 사용 — subnet ID는 apply 전까지 미지수이지만
# 인덱스(0, 1, 2)는 변수에서 개수가 정해지므로 plan 단계에서 키를 확정할 수 있음
resource "aws_efs_mount_target" "example" {
  for_each        = { for i, v in module.vpc.private_subnets : tostring(i) => v }
  file_system_id  = aws_efs_file_system.example.id
  subnet_id       = each.value
  security_groups = [aws_security_group.my_efs_sg.id]
}
