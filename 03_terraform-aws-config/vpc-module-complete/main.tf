# AWS 프로바이더 설정
# - region: 리소스를 생성할 AWS 리전 (us-east-1 = 미국 동부)
# - profile: 내 컴퓨터에 저장된 AWS 계정 정보(자격증명)를 가리키는 이름
provider "aws" {
  region  = local.region
  profile = "my-profile" # 인증에 사용할 AWS CLI 프로파일
}

# 현재 리전에서 사용 가능한 가용 영역(데이터센터 위치) 목록을 AWS에서 자동으로 가져옴
# 예) us-east-1a, us-east-1b, us-east-1c
data "aws_availability_zones" "available" {}

# 여러 곳에서 반복 사용하는 값들을 한 곳에 모아둔 로컬 변수
locals {
  name   = "ex-${basename(path.cwd)}" # 현재 폴더 이름을 이용해 리소스 이름 자동 생성
  region = "us-east-1"                # 모든 리소스를 생성할 AWS 리전

  vpc_cidr = "10.0.0.0/16" # VPC 전체 IP 대역 (약 65,000개 IP 사용 가능)

  # 가용 영역 목록에서 앞의 3개만 선택 (멀티 AZ 구성을 위해)
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # 모든 리소스에 공통으로 붙일 태그 (관리/식별 목적)
  tags = {
    Example    = local.name
    GithubRepo = "terraform-aws-vpc"
    GithubOrg  = "terraform-aws-modules"
  }
}

################################################################################
# VPC Module
# AWS 공식 VPC 모듈을 사용해 네트워크 전체 구조를 한 번에 생성
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6.1"

  name = local.name      # VPC 이름
  cidr = local.vpc_cidr  # VPC 전체 IP 대역

  azs = local.azs # 리소스를 배치할 가용 영역 목록 (3개)

  # 서브넷: VPC 안에서 용도별로 IP 대역을 나눈 작은 네트워크 단위
  # cidrsubnet(전체대역, 8, 시작번호) → /24 크기의 서브넷을 순서대로 생성
  private_subnets     = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]      # 외부 접근 불가, 앱 서버용
  public_subnets      = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 4)]  # 인터넷 접근 가능, 로드밸런서용
  database_subnets    = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 8)]  # DB 전용 (가장 격리됨)
  elasticache_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 12)] # 캐시 서버(Redis 등)용
  redshift_subnets    = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 16)] # 데이터 웨어하우스용
  intra_subnets       = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 20)] # 인터넷 없는 내부 통신 전용

  # 각 서브넷의 이름 지정 (지정하지 않으면 자동 생성)
  private_subnet_names     = ["Private Subnet One", "Private Subnet Two"]
  # public_subnet_names omitted to show default name generation for all three subnets
  database_subnet_names    = ["DB Subnet One"]
  elasticache_subnet_names = ["Elasticache Subnet One", "Elasticache Subnet Two"]
  redshift_subnet_names    = ["Redshift Subnet One", "Redshift Subnet Two", "Redshift Subnet Three"]
  intra_subnet_names       = []

  create_database_subnet_group  = false # DB 서브넷 그룹 자동 생성 안 함 (별도 관리)
  manage_default_network_acl    = false # 기본 네트워크 ACL(방화벽 규칙) 관리 안 함
  manage_default_route_table    = false # 기본 라우팅 테이블 관리 안 함
  manage_default_security_group = false # 기본 보안 그룹 관리 안 함

  enable_dns_hostnames = true # EC2 등 리소스에 DNS 이름 자동 부여 (예: ec2-1-2-3-4.compute-1.amazonaws.com)
  enable_dns_support   = true # VPC 내부 DNS 서버 활성화

  enable_nat_gateway = true # Private 서브넷의 인스턴스가 인터넷에 나갈 수 있도록 NAT 게이트웨이 생성
  single_nat_gateway = true # 비용 절감을 위해 NAT 게이트웨이 1개만 사용 (운영 환경에서는 AZ별로 두는 것을 권장)

  # 고객 게이트웨이: 회사 온프레미스(사무실/IDC) 네트워크 장비 정보 등록
  # 이 정보를 기반으로 AWS와 사무실 간 VPN 터널을 연결할 수 있음
  customer_gateways = {
    IP1 = {
      bgp_asn     = 65112      # BGP 라우팅에 사용하는 AS 번호
      ip_address  = "1.2.3.4"  # 온프레미스 장비의 공인 IP
      device_name = "some_name"
    },
    IP2 = {
      bgp_asn    = 65112
      ip_address = "5.6.7.8"
    }
    IP3 = {
      bgp_asn_extended = 2147483648 # 확장 ASN (4바이트 ASN 사용 시)
      ip_address       = "5.6.7.8"
    }
  }

  enable_vpn_gateway = true # VPN 게이트웨이 생성 (온프레미스 ↔ AWS 간 암호화 터널의 AWS 쪽 끝점)

  # DHCP 옵션: VPC 내 인스턴스가 IP를 받을 때 함께 전달되는 네트워크 설정
  enable_dhcp_options              = true
  dhcp_options_domain_name         = "service.consul"          # 내부 도메인 이름 (서비스 디스커버리용)
  dhcp_options_domain_name_servers = ["127.0.0.1", "10.10.0.2"] # 사용할 DNS 서버 주소

  tags = local.tags
}

################################################################################
# VPC Endpoints Module
# VPC 엔드포인트: 인터넷을 거치지 않고 AWS 서비스(S3, DynamoDB 등)에
# 직접 연결하는 프라이빗 통로 → 보안 강화 + 비용 절감
################################################################################

module "vpc_endpoints" {
  source = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"

  vpc_id = module.vpc.vpc_id # 엔드포인트를 연결할 VPC

  # 엔드포인트 전용 보안 그룹 생성
  create_security_group      = true
  security_group_name_prefix = "${local.name}-vpc-endpoints-"
  security_group_description = "VPC endpoint security group"
  security_group_rules = {
    ingress_https = {
      description = "HTTPS from VPC"
      cidr_blocks = [module.vpc.vpc_cidr_block] # VPC 내부에서 오는 HTTPS(443) 트래픽만 허용
    }
  }

  # 생성할 VPC 엔드포인트 목록
  endpoints = {
    # S3 엔드포인트: S3 버킷에 인터넷 없이 직접 접근
    s3 = {
      service             = "s3"
      private_dns_enabled = true # 프라이빗 DNS 이름으로 접근 가능하게 설정
      dns_options = {
        private_dns_only_for_inbound_resolver_endpoint = false
      }
      tags = { Name = "s3-vpc-endpoint" }
    },
    # DynamoDB 엔드포인트: Gateway 타입 (라우팅 테이블 기반, 무료)
    dynamodb = {
      service         = "dynamodb"
      service_type    = "Gateway" # Gateway 타입은 비용 없음 (Interface 타입은 시간당 과금)
      route_table_ids = flatten([module.vpc.intra_route_table_ids, module.vpc.private_route_table_ids, module.vpc.public_route_table_ids])
      policy          = data.aws_iam_policy_document.dynamodb_endpoint_policy.json # 이 VPC에서만 접근 허용하는 정책 적용
      tags            = { Name = "dynamodb-vpc-endpoint" }
    },
    # ECS 엔드포인트: ECS 컨테이너 서비스와 통신용
    ecs = {
      service             = "ecs"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets # Private 서브넷에 엔드포인트 배치
      subnet_configurations = [
        # 각 서브넷에서 고정 IP(10번)를 엔드포인트에 할당
        for v in module.vpc.private_subnet_objects :
        {
          ipv4      = cidrhost(v.cidr_block, 10) # 서브넷 내 10번째 IP를 고정 배정
          subnet_id = v.id
        }
      ]
    },
    # ECS 텔레메트리 엔드포인트: 비활성화 예시 (create = false)
    ecs_telemetry = {
      create              = false # 이 엔드포인트는 생성하지 않음
      service             = "ecs-telemetry"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    },
    # ECR API 엔드포인트: 컨테이너 이미지 저장소(ECR) API 접근용
    ecr_api = {
      service             = "ecr.api"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      policy              = data.aws_iam_policy_document.generic_endpoint_policy.json # VPC 외부 접근 차단 정책
    },
    # ECR Docker 엔드포인트: 컨테이너 이미지 실제 pull/push 용
    ecr_dkr = {
      service             = "ecr.dkr"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      policy              = data.aws_iam_policy_document.generic_endpoint_policy.json
    },
    # RDS 엔드포인트: 관계형 데이터베이스 서비스 접근용
    rds = {
      service             = "rds"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      security_group_ids  = [aws_security_group.rds.id] # 아래에서 정의한 RDS 전용 보안 그룹 적용
    },
  }

  tags = merge(local.tags, {
    Project  = "Secret"
    Endpoint = "true"
  })
}

# 비활성화 예시용 모듈: create = false 옵션으로 실제 리소스를 만들지 않음
# 코드는 유지하되 배포는 건너뛰고 싶을 때 사용하는 패턴
module "vpc_endpoints_nocreate" {
  source = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"

  create = false
}

################################################################################
# Supporting Resources
# VPC 엔드포인트와 보안 그룹에서 참조하는 부속 리소스들
################################################################################

# DynamoDB 엔드포인트 접근 정책
# 이 VPC에서 오는 요청만 허용하고, 외부에서 오는 DynamoDB 요청은 모두 거부
data "aws_iam_policy_document" "dynamodb_endpoint_policy" {
  statement {
    effect    = "Deny"       # 아래 조건에 해당하면 거부
    actions   = ["dynamodb:*"] # DynamoDB의 모든 작업에 적용
    resources = ["*"]

    principals {
      type        = "*"
      identifiers = ["*"] # 모든 주체(사용자, 서비스)에게 적용
    }

    # 조건: 요청이 이 VPC에서 오지 않은 경우 → 즉 VPC 외부 요청을 차단
    condition {
      test     = "StringNotEquals"
      variable = "aws:sourceVpc"

      values = [module.vpc.vpc_id]
    }
  }
}

# 범용 엔드포인트 접근 정책
# ECR 등 여러 서비스에 공통으로 적용: 이 VPC 외부에서의 접근을 모두 차단
data "aws_iam_policy_document" "generic_endpoint_policy" {
  statement {
    effect    = "Deny"
    actions   = ["*"] # 모든 AWS API 작업에 적용
    resources = ["*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    # 조건: 요청 출처가 이 VPC가 아닌 경우 → 거부
    condition {
      test     = "StringNotEquals"
      variable = "aws:SourceVpc"

      values = [module.vpc.vpc_id]
    }
  }
}

# RDS(데이터베이스) 전용 보안 그룹
# PostgreSQL 기본 포트(5432)로 들어오는 연결을 VPC 내부에서만 허용
resource "aws_security_group" "rds" {
  name_prefix = "${local.name}-rds"
  description = "Allow PostgreSQL inbound traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "TLS from VPC"
    from_port   = 5432              # PostgreSQL 포트
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block] # VPC 내부 IP 대역에서만 접근 허용
  }

  tags = local.tags
}
