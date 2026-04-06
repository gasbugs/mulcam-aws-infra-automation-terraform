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
instance_type = "t3.micro"
instance_name = "db_client"

#######################################
# RDS에 대한 변수
# 접근 허용 CIDR
# Aurora 클러스터 식별자
cluster_identifier = "my-aurora-cluster"

# db_engine_version은 기본적으로 자동 조회 — 버전을 고정하려면 아래 주석 해제
# db_engine_version = "8.0.mysql_aurora.3.12.0"

# 마스터 사용자 이름 및 비밀번호
db_username = "admin"         # 원하는 마스터 사용자 이름
db_password = "your-password" # 안전한 마스터 비밀번호 (보안에 유의)

# Aurora 엔진 버전
db_engine_version = "8.0.mysql_aurora.3.11.1"   # 초기 배포 버전
#db_engine_version = "8.0.mysql_aurora.3.12.0" # 2단계 업그레이드 버전

# Aurora 인스턴스 클래스
db_instance_class = "db.t3.medium" # 초기 배포 — Aurora MySQL 3.x 지원 최소 클래스
# db_instance_class = "db.r8g.large" # 2단계 업그레이드 인스턴스

# 접근 허용 CIDR
allowed_cidr = "10.0.0.0/16"

# Aurora 인스턴스 수 (1=쓰기만, 3=쓰기+읽기+읽기)
aurora_instance_count = 1

# 백업 보존 기간 (일)
backup_retention_days = 7
