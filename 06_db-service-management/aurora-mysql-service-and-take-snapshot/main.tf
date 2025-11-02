module "vpc" {
  source             = "./modules/vpc"
  vpc_name           = var.vpc_name
  vpc_cidr           = var.vpc_cidr
  public_subnets     = var.public_subnets
  private_subnets    = var.private_subnets
  availability_zones = var.availability_zones
}

/*
module "ec2" {
  source = "./modules/ec2"

  ami_id          = var.ami_id
  instance_type   = var.instance_type
  vpc_id          = module.vpc.vpc_id
  subnet_id       = module.vpc.public_subnets[0]
  instance_name   = var.instance_name
  public_key_path = var.public_key_path
}
*/

resource "aws_security_group" "rds_sg" {
  name        = "rds-security-group"
  description = "Allow database access"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.vpc_name}-db-subnet-group"
  subnet_ids = module.vpc.private_subnets

  tags = {
    Name = "${var.vpc_name}-db-subnet-group"
  }
}

# Aurora 클러스터 생성
resource "aws_rds_cluster" "my_aurora_cluster" {
  cluster_identifier      = var.cluster_identifier
  engine                  = "aurora-mysql" # 엔진 종류 (MySQL 호환 Aurora)
  engine_version          = var.db_engine_version
  master_username         = var.db_username
  master_password         = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  skip_final_snapshot     = true             # 삭제 시 최종 스냅샷 생성 여부
  backup_retention_period = 7                # 백업 보존 기간 (일)
  preferred_backup_window = "07:00-09:00"    # 백업을 원하는 시간
  database_name           = "thisiscustomdb" # 커스텀 DB를 구성합니다. 

  tags = {
    Name        = "My-Aurora-Cluster"
    Environment = var.environment
  }
}

# Aurora 클러스터 인스턴스 생성
resource "aws_rds_cluster_instance" "my_aurora_instance" {
  cluster_identifier   = aws_rds_cluster.my_aurora_cluster.id
  instance_class       = var.db_instance_class # 인스턴스 클래스
  engine               = "aurora-mysql"        # 클러스터와 동일한 엔진 설정
  db_subnet_group_name = aws_db_subnet_group.this.name
  publicly_accessible  = false # 퍼블릭 액세스 설정

  tags = {
    Name        = "My-Aurora-Instance"
    Environment = var.environment
  }
}

/*
# Aurora 클러스터 생성
resource "aws_rds_cluster" "my_aurora_cluster" {
  cluster_identifier      = "my-aurora-cluster"
  engine                  = "aurora-mysql" # 엔진 종류 (MySQL 호환 Aurora)
  engine_version          = "8.0.mysql_aurora.3.06.1"
  master_username         = "admin"
  master_password         = "YourPassword123!" # 실제 사용 시 안전한 비밀번호를 입력
  db_subnet_group_name    = aws_db_subnet_group.my_db_subnet_group.name
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  skip_final_snapshot     = true          # 삭제 시 최종 스냅샷 생성 여부
  backup_retention_period = 7             # 백업 보존 기간 (일)
  preferred_backup_window = "07:00-09:00" # 백업을 원하는 시간 (UTC 기준)
  storage_encrypted       = true          # 스토리지 암호화 여부
  # kms_key_id            = "arn:aws:kms:us-east-1:123456789012:key/your-kms-key-id"  # KMS 키 지정 (선택 사항)
  preferred_maintenance_window = "mon:03:00-mon:04:00" # 유지 관리 창 (UTC 기준)
  deletion_protection          = true                  # 삭제 보호 활성화 (실수로 삭제 방지)

  tags = {
    Name        = "My-Aurora-Cluster"
    Environment = "Production"
  }
}

# Aurora 클러스터 인스턴스 생성
resource "aws_rds_cluster_instance" "my_aurora_instance" {
  cluster_identifier           = aws_rds_cluster.my_aurora_cluster.id
  instance_class               = "db.r5.large"  # 인스턴스 클래스
  engine                       = "aurora-mysql" # 클러스터와 동일한 엔진 설정
  db_subnet_group_name         = aws_db_subnet_group.my_db_subnet_group.name
  publicly_accessible          = false # 퍼블릭 액세스 설정
  monitoring_interval          = 60    # 강화된 모니터링 간격 (초 단위)
  performance_insights_enabled = true  # Aurora 성능 통찰력 활성화

  tags = {
    Name        = "My-Aurora-Instance"
    Environment = "Production"
  }
}
*/

resource "aws_db_cluster_snapshot" "rds_snapshot" {
  db_cluster_identifier          = aws_rds_cluster.my_aurora_cluster.id
  db_cluster_snapshot_identifier = "tf-snapshot-${replace(lower(timestamp()), ":", "-")}"
}


