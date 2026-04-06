# VPC 모듈 — 퍼블릭/프라이빗 서브넷이 포함된 네트워크 환경 구성
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name                 = "example-vpc"
  cidr                 = var.vpc_cidr                                                        # tfvars에서 CIDR 주입
  azs                  = [for az in var.availability_zones : "${var.aws_region}${az}"]       # 가용 영역 조합
  public_subnets       = var.public_subnet_cidrs                                             # 퍼블릭 서브넷 CIDR
  private_subnets      = var.private_subnet_cidrs                                            # 프라이빗 서브넷 CIDR
  enable_dns_hostnames = true                                                                # DNS 호스트 이름 활성화
  enable_dns_support   = true                                                                # DNS 지원 활성화

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


# DynamoDB 모듈 — 테이블 및 VPC Gateway 엔드포인트 생성
module "dynamodb" {
  source                  = "./modules/dynamodb"
  table_name              = var.dynamodb_table_name
  hash_key                = var.dynamodb_hash_key
  hash_key_type           = var.dynamodb_hash_key_type
  range_key               = var.dynamodb_range_key
  range_key_type          = var.dynamodb_range_key_type
  billing_mode            = var.dynamodb_billing_mode
  read_capacity           = var.dynamodb_read_capacity
  write_capacity          = var.dynamodb_write_capacity
  vpc_id                  = module.vpc.vpc_id
  private_route_table_ids = module.vpc.private_route_table_ids # Gateway 엔드포인트 연결용 라우팅 테이블
  region                  = var.aws_region
  project_name            = var.project_name
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

# EC2 모듈 — 실습용 클라이언트 인스턴스 생성
module "ec2" {
  source                  = "./modules/ec2"
  vpc_id                  = module.vpc.vpc_id
  subnet_id               = module.vpc.public_subnets[0]
  ami_id                  = var.ec2_ami_id
  instance_type           = var.ec2_instance_type
  project_name            = var.project_name
  allowed_ssh_cidr_blocks = var.ec2_allowed_ssh_cidr_blocks
  redis_cidr_blocks       = var.redis_allowed_cidr_blocks
  user_data               = var.ec2_user_data
  ec2_instance_profile    = module.dynamodb.ec2_instance_profile
}
