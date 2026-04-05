# Terraform 공식 VPC 모듈 사용 (직접 구현 대비 IGW, 라우트 테이블, 태그 등 자동 처리)
# 모듈 문서: https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws" # Terraform 공식 레지스트리의 VPC 모듈
  version = "~> 6.6.1"                      # 6.x.x 버전 사용

  name = var.vpc_name # VPC 이름 (Name 태그에도 자동 적용)
  cidr = var.vpc_cidr # VPC 전체 CIDR 블록

  azs             = var.availability_zones # 서브넷을 배치할 가용 영역 목록
  public_subnets  = var.public_subnets     # 퍼블릭 서브넷 CIDR 목록 (IGW 라우트 자동 생성)
  private_subnets = var.private_subnets    # 프라이빗 서브넷 CIDR 목록

  # DNS 설정 (RDS 엔드포인트를 도메인으로 접근하려면 반드시 활성화 필요)
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = var.vpc_name    # VPC 이름 태그
    Environment = var.environment # 환경 태그
  }
}

# Amazon Linux 2023 최신 AMI를 자동으로 조회 (수동으로 AMI ID를 찾을 필요 없음)
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# AWS에서 MySQL의 최신 기본 엔진 버전을 자동으로 조회
# - default_only = true: AWS가 권장하는 안정적인 기본 버전을 반환
# - 변수(var.db_engine_version)로 직접 지정도 가능하며, null이면 이 데이터 소스 값을 사용
# - 특정 버전 고정: terraform.tfvars에서 db_engine_version = "8.0.36" 처럼 설정
#   (고정 시 이 data 소스는 coalesce에 의해 무시됨)
data "aws_rds_engine_version" "mysql" {
  engine       = "mysql"
  default_only = true
}

locals {
  # 실제 사용할 MySQL 버전 (변수 지정 우선, 없으면 data 소스의 최신 기본 버전)
  mysql_version = coalesce(var.db_engine_version, data.aws_rds_engine_version.mysql.version)

  # 버전에서 "major.minor" 추출 (예: "8.4.7" → "8.4", "8.0.36" → "8.0")
  # 파라미터 그룹 패밀리가 major.minor 단위로 구분되기 때문에 필요
  mysql_major_minor = "${split(".", local.mysql_version)[0]}.${split(".", local.mysql_version)[1]}"

  # 파라미터 그룹: 변수로 직접 지정하면 그대로 사용, null이면 버전에 맞게 자동 결정
  # 예) MySQL 8.4.x → "default.mysql8.4", MySQL 8.0.x → "default.mysql8.0"
  parameter_group_name = coalesce(var.db_parameter_group_name, "default.mysql${local.mysql_major_minor}")
}

module "ec2" {
  source = "./modules/ec2" # EC2 모듈 경로

  ami_id           = data.aws_ami.al2023.id       # AMI ID
  instance_type    = var.instance_type            # EC2 인스턴스 타입
  vpc_id           = module.vpc.vpc_id            # VPC ID
  subnet_id        = module.vpc.public_subnets[0] # 퍼블릭 서브넷 ID (첫 번째 서브넷)
  instance_name    = var.instance_name            # 인스턴스 이름
  allowed_ssh_cidr = var.allowed_ssh_cidr         # SSH 접근 허용 CIDR
}

# RDS에 대한 보안 그룹 (MySQL 포트만 허용)
resource "aws_security_group" "rds_sg" {
  name        = "rds-security-group"    # 보안 그룹 이름
  description = "Allow database access" # 보안 그룹 설명
  vpc_id      = module.vpc.vpc_id       # VPC ID

  ingress {
    from_port   = 3306               # 시작 포트 (MySQL 기본 포트)
    to_port     = 3306               # 종료 포트 (MySQL 기본 포트)
    protocol    = "tcp"              # 프로토콜 (TCP)
    cidr_blocks = [var.allowed_cidr] # 접근 허용 CIDR
  }

  egress {
    from_port   = 0             # 모든 포트 허용 (출력 트래픽)
    to_port     = 0             # 모든 포트 허용 (출력 트래픽)
    protocol    = "-1"          # 모든 프로토콜 허용
    cidr_blocks = ["0.0.0.0/0"] # 모든 IP에 출력 허용
  }

  tags = {
    Name        = "rds-security-group" # 보안 그룹 이름 태그
    Environment = var.environment      # 환경 태그
  }
}

# RDS 인스턴스를 배치할 서브넷 그룹 (프라이빗 서브넷에 배치하여 외부 노출 방지)
resource "aws_db_subnet_group" "this" {
  name       = "${var.vpc_name}-db-subnet-group" # DB 서브넷 그룹 이름
  subnet_ids = module.vpc.private_subnets        # 프라이빗 서브넷 ID 목록

  tags = {
    Name        = "${var.vpc_name}-db-subnet-group" # 태그 이름 설정
    Environment = var.environment                   # 환경 태그
  }
}

# RDS MySQL 인스턴스 (주 인스턴스)
resource "aws_db_instance" "my_rds_instance" {
  allocated_storage = var.db_allocated_storage # RDS 인스턴스의 스토리지 크기 (GiB)
  engine            = "mysql"                  # 데이터베이스 엔진 (MySQL)
  # locals에서 버전과 파라미터 그룹을 함께 결정 (버전-파라미터 그룹 불일치 방지)
  engine_version       = local.mysql_version        # 자동 또는 고정 버전
  instance_class       = var.db_instance_class      # 인스턴스 유형
  db_name              = var.db_name                # 데이터베이스 이름
  username             = var.db_username            # 관리자 계정 이름
  password             = var.db_password            # 관리자 계정 비밀번호
  parameter_group_name = local.parameter_group_name # 엔진 버전에 맞게 자동 결정
  skip_final_snapshot  = true                       # 삭제 시 최종 스냅샷 생성하지 않음
  publicly_accessible  = false                      # 퍼블릭 액세스 비활성화
  multi_az             = var.db_multi_az            # 다중 가용 영역 배포 여부

  vpc_security_group_ids = [aws_security_group.rds_sg.id] # 적용할 보안 그룹 ID
  db_subnet_group_name   = aws_db_subnet_group.this.name  # DB 서브넷 그룹 이름

  # 백업 관련 설정
  backup_retention_period = 7             # 백업 보존 기간 (일 단위)
  backup_window           = "02:00-03:00" # 백업 시작 시간 (UTC 기준)

  # 모니터링 및 유지관리
  maintenance_window = "sun:05:00-sun:06:00" # 유지보수 시간 (UTC 기준)

  # 스토리지 설정 (gp3: gp2 대비 저렴하고 성능이 좋은 최신 범용 SSD)
  storage_type      = "gp3" # 스토리지 유형 (gp3 권장)
  storage_encrypted = true  # 저장 데이터 암호화 활성화 (규정 준수 및 보안 강화)

  tags = {
    Name        = "My-RDS-MySQL"  # RDS 인스턴스 이름 태그
    Environment = var.environment # 환경 태그
  }
}

# 읽기 복제본 인스턴스 (읽기 트래픽 분산을 위해 주 인스턴스를 복제)
resource "aws_db_instance" "read_replica" {
  instance_class      = var.db_instance_class # 주 인스턴스와 동일한 인스턴스 유형 사용
  publicly_accessible = false                 # 퍼블릭 액세스 비활성화
  skip_final_snapshot = true                  # 최종 스냅샷 미생성

  replicate_source_db = aws_db_instance.my_rds_instance.identifier # 복제할 원본 인스턴스 ID

  tags = {
    Name        = "My-RDS-Read-Replica" # 복제본 인스턴스 이름 태그
    Environment = var.environment       # 환경 태그 (변수 사용으로 일관성 유지)
  }
}
