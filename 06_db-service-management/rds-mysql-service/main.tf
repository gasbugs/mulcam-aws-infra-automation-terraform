module "vpc" {
  source             = "./modules/vpc"        # VPC 모듈 경로
  vpc_name           = var.vpc_name           # VPC 이름
  vpc_cidr           = var.vpc_cidr           # VPC CIDR 블록
  public_subnets     = var.public_subnets     # 퍼블릭 서브넷 리스트
  private_subnets    = var.private_subnets    # 프라이빗 서브넷 리스트
  availability_zones = var.availability_zones # 가용 영역 리스트
}

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

module "ec2" {
  source = "./modules/ec2" # EC2 모듈 경로

  ami_id          = data.aws_ami.al2023.id       # AMI ID
  instance_type   = var.instance_type            # EC2 인스턴스 타입
  vpc_id          = module.vpc.vpc_id            # VPC ID
  subnet_id       = module.vpc.public_subnets[0] # 퍼블릭 서브넷 ID (첫 번째 서브넷)
  instance_name   = var.instance_name            # 인스턴스 이름
  public_key_path = var.public_key_path          # 공개 키 경로
}

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
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.vpc_name}-db-subnet-group" # DB 서브넷 그룹 이름
  subnet_ids = module.vpc.private_subnets        # 프라이빗 서브넷 ID 목록

  tags = {
    Name = "${var.vpc_name}-db-subnet-group" # 태그 이름 설정
  }
}

resource "aws_db_instance" "my_rds_instance" {
  allocated_storage      = var.db_allocated_storage       # RDS 인스턴스의 스토리지 크기 (GiB)
  engine                 = "mysql"                        # 데이터베이스 엔진 (MySQL)
  engine_version         = var.db_engine_version          # 데이터베이스 엔진 버전
  instance_class         = var.db_instance_class          # 인스턴스 유형
  db_name                = var.db_name                    # 데이터베이스 이름
  username               = var.db_username                # 관리자 계정 이름
  password               = var.db_password                # 관리자 계정 비밀번호
  parameter_group_name   = var.db_parameter_group_name    # 데이터베이스 파라미터 그룹
  skip_final_snapshot    = true                           # 삭제 시 최종 스냅샷 생성하지 않음
  publicly_accessible    = false                          # 퍼블릭 액세스 비활성화
  multi_az               = var.db_multi_az                # 다중 가용 영역 배포 여부
  vpc_security_group_ids = [aws_security_group.rds_sg.id] # 적용할 보안 그룹 ID
  db_subnet_group_name   = aws_db_subnet_group.this.name  # DB 서브넷 그룹 이름

  # 백업 관련 설정
  backup_retention_period = 7             # 백업 보존 기간 (일 단위)
  backup_window           = "02:00-03:00" # 백업 시작 시간 (UTC 기준)

  # 모니터링 및 유지관리
  maintenance_window = "sun:05:00-sun:06:00" # 유지보수 시간 (UTC 기준)

  # 스토리지 및 암호화 설정
  storage_type = "gp2" # 스토리지 유형 (gp2: 범용 SSD)

  tags = {
    Name        = "My-RDS-MySQL"  # RDS 인스턴스 이름 태그
    Environment = var.environment # 환경 태그
  }
}

/*
resource "aws_db_instance" "my_rds_instance" {
  allocated_storage      = 20                           # 스토리지 크기 (GiB)
  engine                 = "mysql"                      # 데이터베이스 엔진
  engine_version         = "8.0"                        # 엔진 버전
  instance_class         = "db.t3.micro"                # 인스턴스 유형
  db_name                = "mydatabase"                 # 데이터베이스 이름
  username               = "admin"                      # 관리자 사용자 이름
  password               = "password"                   # 관리자 비밀번호
  parameter_group_name   = "default.mysql8.0"           # 파라미터 그룹
  skip_final_snapshot    = true                         # 최종 스냅샷 미생성
  publicly_accessible    = false                        # 퍼블릭 액세스 비활성화
  multi_az               = true                         # 다중 가용 영역 배포
  vpc_security_group_ids = [aws_security_group.rds_sg.id] # 보안 그룹 ID
  db_subnet_group_name   = aws_db_subnet_group.this.name # DB 서브넷 그룹 이름

  # 백업 관련 설정
  backup_retention_period = 7                           # 백업 보존 기간
  backup_window           = "02:00-03:00"               # 백업 시작 시간

  # 모니터링 및 유지관리
  monitoring_interval = 60                              # 모니터링 간격 (초 단위)
  maintenance_window  = "sun:05:00-sun:06:00"           # 유지보수 시간

  # 스토리지 및 암호화 설정
  storage_type      = "gp2"                             # 스토리지 유형
  storage_encrypted = true                              # 스토리지 암호화
  # kms_key_id        = "arn:aws:kms:us-east-1:123456789012:key/your-kms-key-id" # KMS 키 ID

  tags = {
    Name        = "My-RDS-MySQL"                        # 인스턴스 이름 태그
    Environment = "Production"                          # 환경 태그
  }
}
*/

# 읽기 복제본 인스턴스
resource "aws_db_instance" "read_replica" {
  engine              = "mysql"       # 데이터베이스 엔진 (MySQL)
  instance_class      = "db.t3.micro" # 인스턴스 유형
  publicly_accessible = false         # 퍼블릭 액세스 비활성화
  skip_final_snapshot = true          # 최종 스냅샷 미생성

  replicate_source_db = aws_db_instance.my_rds_instance.identifier # 복제할 원본 인스턴스 ID

  tags = {
    Name        = "My-RDS-Read-Replica" # 복제본 인스턴스 이름 태그
    Environment = "Production"          # 환경 태그
  }
}
