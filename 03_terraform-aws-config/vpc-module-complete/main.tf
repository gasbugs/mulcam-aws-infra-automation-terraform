data "aws_availability_zones" "available" {} # 사용 가능한 가용 영역 목록을 가져옴

locals {
  name   = "ex-${basename(path.cwd)}" # 프로젝트 이름을 현재 경로에서 생성
  region = "us-east-1"                # AWS 리전을 "us-east-1"으로 설정

  vpc_cidr = "10.0.0.0/16"                                            # VPC의 CIDR 블록 정의
  azs      = slice(data.aws_availability_zones.available.names, 0, 3) # 상위 3개의 가용 영역 선택

  tags = {
    Example    = local.name              # 태그에 프로젝트 이름 포함
    GithubRepo = "terraform-aws-vpc"     # GitHub 레포지토리 정보
    GithubOrg  = "terraform-aws-modules" # GitHub 조직 정보
  }
}

################################################################################
# VPC Module
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws" # VPC 모듈의 소스 경로
  version = "6.5.0"

  name = local.name     # VPC 이름 설정
  cidr = local.vpc_cidr # VPC의 CIDR 블록 설정

  azs                 = local.azs                                                       # 사용할 가용 영역 목록 설정
  private_subnets     = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]      # 프라이빗 서브넷 CIDR 블록 계산
  public_subnets      = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 4)]  # 퍼블릭 서브넷 CIDR 블록 계산
  database_subnets    = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 8)]  # 데이터베이스 서브넷 CIDR 블록 계산
  elasticache_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 12)] # ElastiCache 서브넷 CIDR 블록 계산
  redshift_subnets    = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 16)] # Redshift 서브넷 CIDR 블록 계산
  intra_subnets       = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 20)] # 내부 서브넷 CIDR 블록 계산

  private_subnet_names     = ["Private Subnet One", "Private Subnet Two"]                            # 프라이빗 서브넷 이름 설정
  database_subnet_names    = ["DB Subnet One"]                                                       # 데이터베이스 서브넷 이름 설정
  elasticache_subnet_names = ["Elasticache Subnet One", "Elasticache Subnet Two"]                    # ElastiCache 서브넷 이름 설정
  redshift_subnet_names    = ["Redshift Subnet One", "Redshift Subnet Two", "Redshift Subnet Three"] # Redshift 서브넷 이름 설정
  intra_subnet_names       = []                                                                      # 내부 서브넷 이름 설정하지 않음

  create_database_subnet_group  = false # 데이터베이스 서브넷 그룹 생성 여부 설정
  manage_default_network_acl    = false # 기본 네트워크 ACL 관리하지 않음
  manage_default_route_table    = false # 기본 라우트 테이블 관리하지 않음
  manage_default_security_group = false # 기본 보안 그룹 관리하지 않음

  enable_dns_hostnames = true # DNS 호스트 이름 활성화
  enable_dns_support   = true # DNS 지원 활성화

  enable_nat_gateway = true # NAT 게이트웨이 활성화
  single_nat_gateway = true # 단일 NAT 게이트웨이 사용

  customer_gateways = {
    IP1 = {
      bgp_asn     = 65112       # 첫 번째 고객 게이트웨이의 BGP ASN 설정
      ip_address  = "1.2.3.4"   # 첫 번째 고객 게이트웨이의 IP 주소 설정
      device_name = "some_name" # 첫 번째 고객 게이트웨이의 장치 이름 설정
    },
    IP2 = {
      bgp_asn    = 65112     # 두 번째 고객 게이트웨이의 BGP ASN 설정
      ip_address = "5.6.7.8" # 두 번째 고객 게이트웨이의 IP 주소 설정
    }
  }

  enable_vpn_gateway = true # VPN 게이트웨이 활성화

  enable_dhcp_options              = true                       # DHCP 옵션 활성화
  dhcp_options_domain_name         = "service.consul"           # DHCP 옵션의 도메인 이름 설정
  dhcp_options_domain_name_servers = ["127.0.0.1", "10.10.0.2"] # DHCP 옵션의 도메인 이름 서버 설정

  # VPC 플로우 로그 설정 (Cloudwatch 로그 그룹 및 IAM 역할 생성)
  vpc_flow_log_iam_role_name            = "vpc-complete-example-role" # VPC 플로우 로그 IAM 역할 이름 설정
  vpc_flow_log_iam_role_use_name_prefix = false                       # IAM 역할 이름 접두사 사용하지 않음
  enable_flow_log                       = true                        # VPC 플로우 로그 활성화
  create_flow_log_cloudwatch_log_group  = true                        # Cloudwatch 로그 그룹 생성
  create_flow_log_cloudwatch_iam_role   = true                        # IAM 역할 생성
  flow_log_max_aggregation_interval     = 60                          # 플로우 로그의 최대 집계 간격 설정

  tags = local.tags # VPC에 태그 적용
}

################################################################################
# VPC Endpoints Module
################################################################################

module "vpc_endpoints" {
  source = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints" # VPC 엔드포인트 모듈 소스 경로

  vpc_id = module.vpc.vpc_id # VPC ID 가져오기

  create_security_group      = true                           # 보안 그룹 생성 여부
  security_group_name_prefix = "${local.name}-vpc-endpoints-" # 보안 그룹 이름 접두사
  security_group_description = "VPC endpoint security group"  # 보안 그룹 설명
  security_group_rules = {
    ingress_https = {
      description = "HTTPS from VPC"            # 보안 그룹 규칙 설명
      cidr_blocks = [module.vpc.vpc_cidr_block] # HTTPS 트래픽 허용 범위 설정
    }
  }

  endpoints = {
    s3 = {
      service             = "s3" # S3 엔드포인트 서비스
      private_dns_enabled = true # 프라이빗 DNS 사용 여부
      dns_options = {
        private_dns_only_for_inbound_resolver_endpoint = false # 인바운드 리졸버 엔드포인트에만 프라이빗 DNS 제한
      }
      tags = { Name = "s3-vpc-endpoint" } # S3 엔드포인트에 태그 적용
    },
    dynamodb = {
      service         = "dynamodb"                                                                                                         # DynamoDB 엔드포인트 서비스
      service_type    = "Gateway"                                                                                                          # 게이트웨이 타입으로 설정
      route_table_ids = flatten([module.vpc.intra_route_table_ids, module.vpc.private_route_table_ids, module.vpc.public_route_table_ids]) # 라우트 테이블 ID 설정
      policy          = data.aws_iam_policy_document.dynamodb_endpoint_policy.json                                                         # 엔드포인트 정책 설정
      tags            = { Name = "dynamodb-vpc-endpoint" }                                                                                 # DynamoDB 엔드포인트에 태그 적용
    },
    ecs = {
      service             = "ecs"                      # ECS 엔드포인트 서비스
      private_dns_enabled = true                       # 프라이빗 DNS 사용 여부
      subnet_ids          = module.vpc.private_subnets # ECS 엔드포인트 서브넷 ID 설정
    },
    ecs_telemetry = {
      create              = false                      # 엔드포인트 생성하지 않음
      service             = "ecs-telemetry"            # ECS 텔레메트리 엔드포인트 서비스
      private_dns_enabled = true                       # 프라이빗 DNS 사용 여부
      subnet_ids          = module.vpc.private_subnets # ECS 텔레메트리 엔드포인트 서브넷 ID 설정
    },
    ecr_api = {
      service             = "ecr.api"                                                 # ECR API 엔드포인트 서비스
      private_dns_enabled = true                                                      # 프라이빗 DNS 사용 여부
      subnet_ids          = module.vpc.private_subnets                                # ECR API 엔드포인트 서브넷 ID 설정
      policy              = data.aws_iam_policy_document.generic_endpoint_policy.json # 엔드포인트 정책 설정
    },
    ecr_dkr = {
      service             = "ecr.dkr"                                                 # ECR Docker 엔드포인트 서비스
      private_dns_enabled = true                                                      # 프라이빗 DNS 사용 여부
      subnet_ids          = module.vpc.private_subnets                                # ECR Docker 엔드포인트 서브넷 ID 설정
      policy              = data.aws_iam_policy_document.generic_endpoint_policy.json # 엔드포인트 정책 설정
    },
    rds = {
      service             = "rds"                       # RDS 엔드포인트 서비스
      private_dns_enabled = true                        # 프라이빗 DNS 사용 여부
      subnet_ids          = module.vpc.private_subnets  # RDS 엔드포인트 서브넷 ID 설정
      security_group_ids  = [aws_security_group.rds.id] # RDS 엔드포인트 보안 그룹 ID 설정
    },
  }

  tags = merge(local.tags, {
    Project  = "Secret" # 프로젝트 태그 추가
    Endpoint = "true"   # 엔드포인트 태그 추가
  })
}

module "vpc_endpoints_nocreate" {
  source = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints" # 엔드포인트 모듈 소스 경로

  create = false # 모듈 생성하지 않음
}

################################################################################
# Supporting Resources
################################################################################

data "aws_iam_policy_document" "dynamodb_endpoint_policy" {
  statement {
    effect    = "Deny"         # 액세스 거부
    actions   = ["dynamodb:*"] # 모든 DynamoDB 작업에 대해 정책 적용
    resources = ["*"]          # 모든 리소스에 대해 정책 적용

    principals {
      type        = "*"   # 모든 주체에 대해 정책 적용
      identifiers = ["*"] # 주체 식별자
    }

    condition {
      test     = "StringNotEquals" # 조건 테스트
      variable = "aws:sourceVpc"   # 조건 변수

      values = [module.vpc.vpc_id] # VPC ID와 일치하지 않을 경우 액세스 거부
    }
  }
}

data "aws_iam_policy_document" "generic_endpoint_policy" {
  statement {
    effect    = "Deny" # 액세스 거부
    actions   = ["*"]  # 모든 작업에 대해 정책 적용
    resources = ["*"]  # 모든 리소스에 대해 정책 적용

    principals {
      type        = "*"   # 모든 주체에 대해 정책 적용
      identifiers = ["*"] # 주체 식별자
    }

    condition {
      test     = "StringNotEquals" # 조건 테스트
      variable = "aws:SourceVpc"   # 조건 변수

      values = [module.vpc.vpc_id] # VPC ID와 일치하지 않을 경우 액세스 거부
    }
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "${local.name}-rds"                # 보안 그룹 이름 접두사 설정
  description = "Allow PostgreSQL inbound traffic" # 보안 그룹 설명
  vpc_id      = module.vpc.vpc_id                  # VPC ID 설정

  ingress {
    description = "TLS from VPC"              # VPC 내에서 TLS 트래픽 허용
    from_port   = 5432                        # PostgreSQL 포트
    to_port     = 5432                        # PostgreSQL 포트
    protocol    = "tcp"                       # TCP 프로토콜 사용
    cidr_blocks = [module.vpc.vpc_cidr_block] # VPC CIDR 블록 범위 내에서 트래픽 허용
  }

  tags = local.tags # 보안 그룹에 태그 적용
}
