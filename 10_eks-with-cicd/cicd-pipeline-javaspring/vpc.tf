# ================================================================
# VPC(Virtual Private Cloud) 네트워크 구성
#
# VPC란?
#   AWS 안에 만드는 나만의 가상 네트워크 공간
#   인터넷과 격리된 프라이빗 네트워크를 구성하고,
#   필요한 부분만 외부에 노출할 수 있음
# ================================================================

# 현재 리전에서 사용 가능한 가용 영역(AZ) 목록 조회
# AZ(Availability Zone): 같은 리전 안의 독립된 데이터센터 그룹
# opt-in-not-required: 별도 신청 없이 기본으로 사용 가능한 AZ만 선택
# (일부 AZ는 Local Zone이라 EKS 노드 그룹 미지원 → 필터로 제외)
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# EKS 클러스터 이름 — 랜덤 suffix로 동일 계정 내 여러 클러스터 구분
locals {
  cluster_name = "education-eks-${random_string.suffix.result}"
}

# 클러스터 이름에 붙일 랜덤 8자리 영숫자 문자열
resource "random_string" "suffix" {
  length  = 8
  special = false
}

# VPC 생성 — terraform-aws-modules/vpc 공개 모듈 사용
# 서브넷·라우팅 테이블·인터넷 게이트웨이·NAT 게이트웨이를 자동으로 생성해 줌
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name = "education-vpc"

  # CIDR 블록: 이 VPC 안에서 사용할 IP 주소 범위
  # 10.0.0.0/16 → 10.0.0.0 ~ 10.0.255.255 (약 65,000개 IP)
  cidr = "10.0.0.0/16"

  # 3개의 AZ에 걸쳐 서브넷 배치 → 한 AZ 장애 시 나머지 AZ로 서비스 유지 가능
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # 프라이빗 서브넷: 인터넷에서 직접 접근 불가 — EKS 노드, CodeBuild 실행 위치
  # 외부와 통신은 NAT 게이트웨이를 통해 단방향(아웃바운드)으로만 가능
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]

  # 퍼블릭 서브넷: 인터넷과 직접 통신 가능 — 로드밸런서(ELB), NAT 게이트웨이 위치
  public_subnets = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  # NAT 게이트웨이: 프라이빗 서브넷 → 인터넷 아웃바운드 트래픽 허용
  # (ECR 이미지 pull, apt install 등에 필요)
  enable_nat_gateway = true

  # single_nat_gateway: NAT 게이트웨이를 1개만 생성 (비용 절감)
  # 운영 환경에서는 AZ별로 1개씩 생성 권장 (고가용성)
  single_nat_gateway = true

  # DNS 호스트 이름 활성화 — EC2 인스턴스에 DNS 이름 자동 부여
  enable_dns_hostnames = true

  # EKS가 자동으로 생성하는 로드밸런서(ALB/NLB/CLB)가 올바른 서브넷에 배치되도록 태그 지정
  # 퍼블릭 서브넷 태그: 인터넷에서 접근 가능한 외부용 로드밸런서 위치
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  # 프라이빗 서브넷 태그: VPC 내부에서만 접근 가능한 내부용 로드밸런서 위치
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}
