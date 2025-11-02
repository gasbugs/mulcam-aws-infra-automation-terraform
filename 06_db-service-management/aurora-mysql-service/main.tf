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
  name       = "${var.vpc_name}-db-subnet-group-0" # DB 서브넷 그룹 이름
  subnet_ids = module.vpc.private_subnets          # 프라이빗 서브넷 ID 목록

  tags = {
    Name = "${var.vpc_name}-db-subnet-group" # 태그 이름 설정
  }
}

resource "aws_rds_cluster" "my_aurora_cluster" {
  cluster_identifier           = "${var.cluster_identifier}-0"  # 클러스터 ID
  engine                       = "aurora-mysql"                 # 엔진 종류 (MySQL 호환 Aurora)
  engine_version               = var.db_engine_version          # 엔진 버전
  master_username              = var.db_username                # 관리자 계정 이름
  master_password              = var.db_password                # 관리자 계정 비밀번호
  db_subnet_group_name         = aws_db_subnet_group.this.name  # DB 서브넷 그룹 이름
  vpc_security_group_ids       = [aws_security_group.rds_sg.id] # VPC 보안 그룹 ID
  skip_final_snapshot          = true                           # 삭제 시 최종 스냅샷 생성 여부
  backup_retention_period      = 7                              # 백업 보존 기간 (일)
  preferred_backup_window      = "07:00-09:00"                  # 백업 시간 (UTC 기준)
  apply_immediately            = true                           # 업데이트 즉시 적용
  preferred_maintenance_window = "mon:05:00-mon:07:00"          # 유지보수 시간 (UTC 기준)

  tags = {
    Name        = "My-Aurora-Cluster" # 클러스터 이름 태그
    Environment = var.environment     # 환경 태그
  }
}

resource "aws_rds_cluster_instance" "my_aurora_instance" {
  count                = 1                                    # 쓰기, 읽기, 읽기
  cluster_identifier   = aws_rds_cluster.my_aurora_cluster.id # 클러스터 ID
  instance_class       = var.db_instance_class                # 인스턴스 클래스
  engine               = "aurora-mysql"                       # 엔진 (Aurora MySQL)
  engine_version       = var.db_engine_version                # 엔진 버전
  db_subnet_group_name = aws_db_subnet_group.this.name        # DB 서브넷 그룹 이름
  publicly_accessible  = false                                # 퍼블릭 액세스 비활성화
  apply_immediately    = true                                 # 업데이트 즉시 적용

  tags = {
    Name        = "My-Aurora-Instance${count.index + 1}" # 인스턴스 이름 태그
    Environment = var.environment                        # 환경 태그
  }
}

/*
# 주석 처리된 예제 코드 (참고용)

resource "aws_rds_cluster" "my_aurora_cluster" {
  cluster_identifier      = "my-aurora-cluster"          # 클러스터 ID
  engine                  = "aurora-mysql"               # 엔진 종류 (MySQL 호환 Aurora)
  engine_version          = "8.0.mysql_aurora.3.10.1"    # 엔진 버전
  master_username         = "admin"                      # 관리자 계정 이름
  master_password         = "YourPassword123!"           # 관리자 비밀번호
  db_subnet_group_name    = aws_db_subnet_group.my_db_subnet_group.name # DB 서브넷 그룹 이름
  vpc_security_group_ids  = [aws_security_group.rds_sg.id] # VPC 보안 그룹 ID
  skip_final_snapshot     = true                         # 삭제 시 최종 스냅샷 생성 여부
  backup_retention_period = 7                            # 백업 보존 기간 (일)
  preferred_backup_window = "07:00-09:00"                # 백업 시간 (UTC 기준)
  storage_encrypted       = true                         # 스토리지 암호화 여부
  preferred_maintenance_window = "mon:03:00-mon:04:00"   # 유지 관리 창 (UTC 기준)
  deletion_protection          = true                    # 삭제 보호 활성화

  tags = {
    Name        = "My-Aurora-Cluster"                    # 클러스터 이름 태그
    Environment = "Production"                           # 환경 태그
  }
}

resource "aws_rds_cluster_instance" "my_aurora_instance" {
  cluster_identifier           = aws_rds_cluster.my_aurora_cluster.id # 클러스터 ID
  instance_class               = "db.r5.large"                # 인스턴스 클래스
  engine                       = "aurora-mysql"               # 엔진 (Aurora MySQL)
  db_subnet_group_name         = aws_db_subnet_group.my_db_subnet_group.name # DB 서브넷 그룹 이름
  publicly_accessible          = false                       # 퍼블릭 액세스 비활성화
  monitoring_interval          = 60                          # 모니터링 간격 (초)
  performance_insights_enabled = true                        # 성능 통찰력 활성화

  tags = {
    Name        = "My-Aurora-Instance"                      # 인스턴스 이름 태그
    Environment = "Production"                             # 환경 태그
  }
}
*/
