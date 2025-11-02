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

  name = "education-vpc" # VPC의 이름

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

# EKS 클러스터 생성 모듈을 정의. Terraform의 EKS 모듈을 사용
module "eks" {
  source  = "terraform-aws-modules/eks/aws" # EKS 모듈의 소스 경로
  version = "20.26.0"                       # EKS 모듈의 버전

  # 클러스터 이름과 버전 설정
  cluster_name    = local.cluster_name # 로컬에서 정의한 클러스터 이름 사용
  cluster_version = "1.33"             # EKS 클러스터의 버전 설정

  cluster_endpoint_public_access           = true # 클러스터의 퍼블릭 엔드포인트 접근을 허용
  enable_cluster_creator_admin_permissions = true # 클러스터 생성자에게 관리 권한 부여

  # 클러스터 추가 기능 설정 (EBS CSI 드라이버)
  cluster_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.irsa-ebs-csi.iam_role_arn # IRSA로 연동된 역할의 ARN 사용
    }
  }

  vpc_id     = module.vpc.vpc_id          # 생성된 VPC ID 사용
  subnet_ids = module.vpc.private_subnets # 생성된 사설 서브넷 사용

  # EKS 관리형 노드 그룹 기본 설정
  eks_managed_node_group_defaults = {
    ami_type = "AL2023_x86_64_STANDARD" # Amazon Linux 2023 사용
  }

  # EKS 관리형 노드 그룹 정의
  eks_managed_node_groups = {
    one = {
      name = "node-group-1" # 첫 번째 노드 그룹 이름

      instance_types = ["t3.small"] # 노드 인스턴스 유형

      min_size     = 1 # 최소 노드 수
      max_size     = 3 # 최대 노드 수
      desired_size = 2 # 원하는 노드 수
    }

    two = {
      name = "node-group-2" # 두 번째 노드 그룹 이름

      instance_types = ["t3.small"] # 노드 인스턴스 유형

      min_size     = 1 # 최소 노드 수
      max_size     = 2 # 최대 노드 수
      desired_size = 1 # 원하는 노드 수
    }
  }
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
