# VPC Module
# VPC 모듈 생성
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0" # 원하는 버전으로 설정

  # VPC 이름 및 CIDR 범위 설정
  name             = "example-vpc"
  cidr             = "10.0.0.0/16"
  azs              = ["${var.aws_region}a", "${var.aws_region}b"] # 가용 영역 설정
  public_subnets   = ["10.0.1.0/24", "10.0.2.0/24"]               # 퍼블릭 서브넷 CIDR
  private_subnets  = ["10.0.3.0/24", "10.0.4.0/24"]               # asg 서브넷 CIDR
  database_subnets = ["10.0.5.0/24", "10.0.6.0/24"]               # rds 서브넷 CIDR

  enable_dns_hostnames = true # DNS 호스트 이름 활성화
  enable_dns_support   = true # DNS 지원 활성화

  # 인터넷 게이트웨이 및 라우팅 테이블 자동 생성
  create_igw = true

  # NAT 게이트웨이 설정 (하나만 사용)
  #enable_nat_gateway = true
  #single_nat_gateway = true # 하나의 NAT 게이트웨이만 사용할 경우 true 설정

  public_subnet_tags = {
    Name = "wordpress-elb-subnet"
  }

  private_subnet_tags = {
    Name = "wordpress-asg-subnet"
  }

  database_subnet_tags = {
    Name = "wordpress-rds-subnet"
  }

  tags = {
    Name = "wordpress-vpc"
  }
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
  subnet_ids = module.vpc.database_subnets         # 프라이빗 서브넷 ID 목록

  tags = {
    Name = "${var.vpc_name}-db-subnet-group" # 태그 이름 설정
  }
}

resource "aws_rds_cluster" "my_aurora_cluster" {
  cluster_identifier            = "${var.cluster_identifier}-0"  # 클러스터 ID
  engine                        = "aurora-mysql"                 # 엔진 종류 (MySQL 호환 Aurora)
  engine_version                = var.db_engine_version          # 엔진 버전
  master_username               = var.db_username                # 관리자 계정 이름
  manage_master_user_password   = true                           # 패스워드 자동 관리 
  master_user_secret_kms_key_id = aws_kms_key.example_key.id     # 속성을 지정하여 특정 KMS 키를 지정
  storage_encrypted             = true                           # 스토리지 암호화 여부
  kms_key_id                    = aws_kms_key.example_key.arn    # 스토리지 암호화에 사용되는 키 
  db_subnet_group_name          = aws_db_subnet_group.this.name  # DB 서브넷 그룹 이름
  vpc_security_group_ids        = [aws_security_group.rds_sg.id] # VPC 보안 그룹 ID
  skip_final_snapshot           = true                           # 삭제 시 최종 스냅샷 생성 여부
  backup_retention_period       = 7                              # 백업 보존 기간 (일)
  preferred_backup_window       = "07:00-09:00"                  # 백업 시간 (UTC 기준)
  apply_immediately             = true                           # 업데이트 즉시 적용
  preferred_maintenance_window  = "mon:05:00-mon:07:00"          # 유지보수 시간 (UTC 기준)

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

# KMS 키 생성 (시크릿 암호화에 사용)
resource "aws_kms_key" "example_key" {
  description             = var.kms_description
  deletion_window_in_days = 10

  policy = jsonencode({
    Version = "2012-10-17",
    Id      = "kms-key-policy",
    Statement = [
      {
        Sid : "Enable IAM User Permissions",
        Effect : "Allow",
        Principal : {
          "AWS" : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/user0"
        },
        Action : "kms:*",
        Resource : "*"
      },
      {
        Sid    = "Allow use of the key by EC2 role",
        Effect = "Allow",
        Principal = {
          AWS = aws_iam_role.ec2_secrets_manager_role.arn
        },
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "random_integer" "secret_suffix" {
  min = 1000
  max = 9999
}
