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

  tags = local.tags

}
