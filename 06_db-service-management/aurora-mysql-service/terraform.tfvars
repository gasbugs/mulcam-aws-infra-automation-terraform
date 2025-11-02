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
# EC2에 대한 변수
instance_type   = "t2.micro"
instance_name   = "db_client"
public_key_path = "~/.ssh/my-key.pub"

#######################################
# RDS에 대한 변수
# 접근 허용 CIDR
# Aurora 클러스터 식별자
cluster_identifier = "my-aurora-cluster"

# Aurora 엔진 버전
# Aurora MySQL의 최신 버전 확인 명령어:
# aws rds describe-db-engine-versions --region us-east-1 --engine aurora-mysql --query '*[]|[?SupportsParallelQuery == `true`].[EngineVersion]' --output text
# db_engine_version = "8.0.mysql_aurora.3.09.0" # 기존 버전
db_engine_version = "8.0.mysql_aurora.3.10.1" # 업그레이드 버전

# 마스터 사용자 이름 및 비밀번호
db_username = "admin"         # 원하는 마스터 사용자 이름
db_password = "your-password" # 안전한 마스터 비밀번호 (보안에 유의)

# Aurora 인스턴스 클래스 # db.r5.xlarge
db_instance_class = "db.r5.xlarge" # 사용하려는 인스턴스 타입 지정


# 접근 허용 CIDR
allowed_cidr = "10.0.0.0/16"
