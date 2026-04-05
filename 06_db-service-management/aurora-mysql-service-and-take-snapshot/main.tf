# VPC 및 서브넷을 생성하는 공식 VPC 모듈 (HashiCorp 공인 모듈)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.vpc_name
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  public_subnets  = var.public_subnets
  private_subnets = var.private_subnets

  # NAT 게이트웨이: 프라이빗 서브넷 → 인터넷 통신을 위해 필요
  enable_nat_gateway = true
  single_nat_gateway = true # 비용 절감을 위해 하나의 NAT 게이트웨이 사용

  tags = {
    Name = var.vpc_name
  }
}

# RDS가 속할 서브넷 그룹 (Aurora는 여러 가용 영역에 걸쳐 배포되므로 복수의 서브넷 필요)
resource "aws_db_subnet_group" "this" {
  name       = "${var.vpc_name}-db-subnet-group"
  subnet_ids = module.vpc.private_subnets

  tags = {
    Name = "${var.vpc_name}-db-subnet-group"
  }
}

# Aurora 클러스터에 대한 네트워크 접근을 제어하는 보안 그룹
resource "aws_security_group" "rds_sg" {
  name        = "rds-security-group"
  description = "Allow database access"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "rds-security-group"
  }
}

# MySQL 포트(3306)로의 인바운드 트래픽 허용 규칙
resource "aws_vpc_security_group_ingress_rule" "rds_mysql" {
  security_group_id = aws_security_group.rds_sg.id
  description       = "Allow MySQL access from allowed CIDR"
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
  cidr_ipv4         = var.allowed_cidr
}

# 모든 아웃바운드 트래픽 허용 규칙 (Aurora → 외부 통신)
resource "aws_vpc_security_group_egress_rule" "rds_all" {
  security_group_id = aws_security_group.rds_sg.id
  description       = "Allow all outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# AWS에서 Aurora MySQL의 현재 기본(최신 권장) 엔진 버전을 자동으로 조회
data "aws_rds_engine_version" "aurora_mysql" {
  engine       = "aurora-mysql"
  default_only = true # AWS가 지정한 기본 버전 선택
}

# Aurora MySQL 클러스터 생성 (고가용성 관계형 DB 서비스)
resource "aws_rds_cluster" "my_aurora_cluster" {
  cluster_identifier      = var.cluster_identifier
  engine                  = "aurora-mysql"       # MySQL 호환 Aurora 엔진
  engine_version          = data.aws_rds_engine_version.aurora_mysql.version # 자동 조회된 기본 버전 사용
  master_username         = var.db_username
  master_password         = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  skip_final_snapshot     = true             # 삭제 시 최종 스냅샷 생성 여부
  backup_retention_period = 7               # 자동 백업 보존 기간 (일)
  preferred_backup_window = "07:00-09:00"   # 백업 수행 시간대 (UTC 기준)
  database_name           = "thisiscustomdb" # 초기 생성할 데이터베이스 이름

  tags = {
    Name = "My-Aurora-Cluster"
  }
}

# Aurora 클러스터에 연결되는 실제 DB 인스턴스 (읽기/쓰기 처리)
resource "aws_rds_cluster_instance" "my_aurora_instance" {
  cluster_identifier   = aws_rds_cluster.my_aurora_cluster.id
  instance_class       = var.db_instance_class # 인스턴스 성능 등급
  engine               = "aurora-mysql"        # 클러스터와 동일한 엔진 사용
  db_subnet_group_name = aws_db_subnet_group.this.name
  publicly_accessible  = false # 외부 인터넷에서 직접 접근 차단

  tags = {
    Name = "My-Aurora-Instance"
  }
}

# Aurora 클러스터의 특정 시점 스냅샷을 생성 (백업/복구 용도)
resource "aws_db_cluster_snapshot" "rds_snapshot" {
  db_cluster_identifier          = aws_rds_cluster.my_aurora_cluster.id
  db_cluster_snapshot_identifier = "tf-snapshot-${replace(lower(timestamp()), ":", "-")}"
}
