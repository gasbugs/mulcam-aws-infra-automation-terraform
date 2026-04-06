# VPC 모듈 — 퍼블릭/프라이빗 서브넷이 포함된 네트워크 환경 구성
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name                 = "example-vpc"
  cidr                 = var.vpc_cidr                                                  # tfvars에서 CIDR 주입
  azs                  = [for az in var.availability_zones : "${var.aws_region}${az}"] # 가용 영역 조합
  public_subnets       = var.public_subnet_cidrs                                       # 퍼블릭 서브넷 CIDR
  private_subnets      = var.private_subnet_cidrs                                      # 프라이빗 서브넷 CIDR
  enable_dns_hostnames = true                                                          # DNS 호스트 이름 활성화
  enable_dns_support   = true                                                          # DNS 지원 활성화

  # 인터넷 게이트웨이 및 라우팅 테이블 자동 생성
  create_igw = true

  # NAT 게이트웨이 설정 (하나만 사용)
  #enable_nat_gateway = true
  #single_nat_gateway = true # 하나의 NAT 게이트웨이만 사용할 경우 true 설정

  public_subnet_tags = {
    Name = "example-public-subnet"
  }

  tags = {
    Name = "example-vpc"
  }
}

# ElastiCache(Valkey) 모듈 — Replication Group 생성
module "elasticache" {
  source               = "./modules/elasticache"
  vpc_id               = module.vpc.vpc_id
  private_subnet_ids   = module.vpc.private_subnets
  project_name         = var.project_name
  allowed_cidr_blocks  = var.redis_allowed_cidr_blocks
  node_type            = var.redis_node_type
  num_cache_nodes      = var.redis_num_cache_nodes
  parameter_group_name = var.redis_parameter_group_name
  redis_auth_token     = var.redis_auth_token

}
