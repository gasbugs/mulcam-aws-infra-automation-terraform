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

  name = "education-vpc"

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
  kubernetes_version = "1.34"

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  # 클러스터에 설치할 Addons 목록 및 IRSA 구성, overwrite 정책 적용
  addons = {
    # Amazon VPC CNI
    vpc-cni = {
      #version                  = "v1.12.7"
      update_policy            = "OVERWRITE"                      # 덮어쓰기 정책 설정
      service_account_role_arn = module.irsa_vpc_cni.iam_role_arn # IRSA 역할 추가
    }

    # CoreDNS
    coredns = {
      #version       = "v1.8.7-eksbuild.1"
      update_policy = "OVERWRITE"
    }

    # Kube-proxy
    kube-proxy = {
      #version       = "v1.20.4-eksbuild.2"
      update_policy = "OVERWRITE"
    }

    # Amazon EBS CSI Driver
    aws-ebs-csi-driver = {
      #version                  = "v1.3.0"
      update_policy            = "OVERWRITE"
      service_account_role_arn = module.irsa-ebs-csi.iam_role_arn # IRSA 역할 추가
    }

    # Amazon EFS CSI Driver
    aws-efs-csi-driver = {
      update_policy            = "OVERWRITE"
      service_account_role_arn = module.irsa-efs-csi.iam_role_arn # IRSA 역할 추가
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
}

module "eks_managed_node_groups" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group" # EKS 관리형 노드 그룹 모듈 경로
  version = "21.8"                                                          # 모듈 버전

  name                 = "on_demand"                     # 첫 번째 노드 그룹 이름
  cluster_name         = module.eks.cluster_name         # EKS 클러스터 이름
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
resource "aws_efs_file_system" "example" {
  creation_token = "efs-example"
  encrypted      = true # 암호화 여부
  tags = {
    Name = "example-efs"
  }
}

# 출력할 EFS 파일 시스템 ID
output "efs_file_system_id" {
  value = aws_efs_file_system.example.id
}


# EFS 보안 그룹 생성
resource "aws_security_group" "my_efs_sg" {
  name        = "efs-sg"
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
    Name = "efs-sg"
  }
}


# 각 서브넷(가용 영역)에 대해 EFS 마운트 타겟 생성
resource "aws_efs_mount_target" "example" {
  for_each        = toset(module.vpc.private_subnets) # 모든 프라이빗 서브넷에 대해 반복
  file_system_id  = aws_efs_file_system.example.id
  subnet_id       = each.value
  security_groups = [aws_security_group.my_efs_sg.id]

  depends_on = [module.vpc.private_subnets]
}
