# HashiCorp에서 제공하는 예시 코드, MPL-2.0 라이선스에 따라 배포됨
# 이 코드는 EKS 클러스터를 프로비저닝하기 위한 기본 설정을 포함
# 원본은 HashiCorp GitHub에서 확인 가능: https://github.com/hashicorp/learn-terraform-provision-eks-cluster/blob/main/main.tf

# AWS의 사용 가능한 가용 영역 중에서 관리형 노드 그룹에 지원되지 않는 Local Zone을 필터링
# 'opt-in-not-required' 상태인 가용 영역만 선택하여 사용
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

# VPC 생성 모듈을 정의. Terraform의 VPC 모듈을 사용해 VPC를 프로비저닝
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

# EKS 클러스터 생성 모듈을 정의. Terraform의 EKS 모듈을 사용
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.26.0"

  cluster_name    = local.cluster_name
  cluster_version = "1.33"

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  # 클러스터에 설치할 Top 10 Addons 추가
  cluster_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_group_defaults = {
    ami_type = "AL2023_x86_64_STANDARD" # Amazon Linux 2023 사용
  }

  eks_managed_node_groups = {
    on_demand = {
      desired_capacity = 1
      max_capacity     = 4
      min_capacity     = 1

      instance_types = ["c5.large"]
      labels = {
        type = "on-demand"
      }
    }
  }
}


# EBS CSI 드라이버 정책을 불러옴
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# IRSA 모듈 정의 (EBS CSI)
module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.20"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}
