# AWS 환경 설정
aws_region  = "us-east-1"
aws_profile = "my-profile"
environment = "Production"

#######################################
# VPC에 대한 변수
vpc_name           = "my-vpc"
vpc_cidr           = "10.0.0.0/16"
public_subnets     = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnets    = ["10.0.3.0/24", "10.0.4.0/24"]
availability_zones = ["us-east-1a", "us-east-1b"]

#######################################
# RDS에 대한 변수
# 접근 허용 CIDR
allowed_cidr = "10.0.0.0/16"

# RDS 인스턴스 설정
# db_engine_version을 생략하면 AWS 기본 최신 버전이 자동으로 사용됨
# 특정 버전으로 고정하려면 아래 주석을 해제 (사용 가능한 버전 목록: aws rds describe-db-engine-versions --engine mysql)
# db_engine_version = "8.0.36"
db_allocated_storage = 20
db_instance_class    = "db.t3.micro"
db_name              = "mydatabase"

# RDS 보안 설정
db_username = "admin"
db_password = "securepassword123!" # 민감 정보, 환경 변수로도 관리 가능

# DB Parameter Group: 생략하면 엔진 버전에서 자동 결정 (예: MySQL 8.4.x → default.mysql8.4)
# 특정 파라미터 그룹을 사용하려면 아래 주석 해제
# db_parameter_group_name = "default.mysql8.4"

# RDS 멀티 AZ 설정
db_multi_az = true

#######################################
# EC2에 대한 변수
instance_type = "t3.micro"
instance_name = "db_client"
# SSH 키는 tls_private_key로 자동 생성되며 ec2-key.pem 파일로 저장됨 (public_key_path 불필요)
# SSH 접근을 허용할 CIDR — 실무에서는 관리자 IP로 제한 권장 (예: "203.0.113.10/32")
allowed_ssh_cidr = "0.0.0.0/0"
