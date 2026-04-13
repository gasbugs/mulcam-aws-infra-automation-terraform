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
  enable_nat_gateway = true
  single_nat_gateway = true # 하나의 NAT 게이트웨이만 사용할 경우 true 설정

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


resource "aws_db_subnet_group" "wordpress_rds_subnet_group" {
  name       = "wordpress-rds-subnet-group"
  subnet_ids = module.vpc.database_subnets


  tags = {
    Name = "WordPress DB subnet group"
  }
}

resource "aws_security_group" "rds_mysql_sg" {
  name        = "rds-mysql-security-group"
  description = "Security group for RDS MySQL instance"
  vpc_id      = module.vpc.vpc_id # VPC ID를 변수로 받아옵니다

  # MySQL 포트(3306)에 대한 인바운드 규칙
  ingress {
    description = "Allow MySQL traffic from VPC"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = concat(module.vpc.public_subnets_cidr_blocks, module.vpc.private_subnets_cidr_blocks) # VPC의 CIDR 블록을 변수로 받아옵니다
  }

  # 모든 아웃바운드 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rds-mysql-sg"
  }
}

resource "aws_db_instance" "wordpress" {
  identifier           = "wordpressdb"
  allocated_storage    = 20
  storage_type         = "gp3" # gp2보다 성능이 좋고 비용이 저렴한 최신 스토리지 타입
  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = "db.t3.micro"
  db_name              = "wordpressdb"
  username             = var.db_username
  password             = var.db_password
  parameter_group_name = "default.mysql8.0"
  db_subnet_group_name = aws_db_subnet_group.wordpress_rds_subnet_group.name
  skip_final_snapshot  = true
  multi_az             = true

  vpc_security_group_ids = [aws_security_group.rds_mysql_sg.id]
}

resource "aws_efs_file_system" "wordpress_efs" {
  creation_token = "wordpress-efs"

  tags = {
    Name = "WordPress EFS"
  }
}

# EFS(공유 파일 스토리지)에 대한 NFS 접근을 제어하는 보안 그룹
resource "aws_security_group" "efs_sg" {
  name        = "efs-security-group"
  description = "Security group for EFS mount targets - allows NFS(2049) from internal VPC"
  vpc_id      = module.vpc.vpc_id
  ingress {
    description = "Allow NFS access from within VPC"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = concat(module.vpc.public_subnets_cidr_blocks, module.vpc.private_subnets_cidr_blocks) # VPC의 CIDR 블록을 변수로 받아옵니다
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "efs-security-group"
  }
}

resource "aws_efs_mount_target" "efs_mount" {
  count           = 2
  file_system_id  = aws_efs_file_system.wordpress_efs.id
  subnet_id       = module.vpc.database_subnets[count.index]
  security_groups = [aws_security_group.efs_sg.id]
}

# Packer를 사용해 WordPress가 설치된 EC2 AMI(머신 이미지)를 빌드하는 리소스
# terraform_data는 null_resource를 대체하는 최신 방식 (Terraform 1.4.0+)
resource "terraform_data" "packer_build" {
  provisioner "local-exec" {
    # AWS_PROFILE을 명시적으로 지정하여 Packer가 올바른 자격증명을 사용하도록 설정
    # (Packer는 기본적으로 default 프로파일을 사용하므로 반드시 명시 필요)
    environment = {
      AWS_PROFILE = "my-profile"
    }
    command = <<-EOT
      packer build \
        -force \
        -var "subnet_id=${module.vpc.public_subnets[0]}" \
        -var "db_username=${var.db_username}" \
        -var "db_password=${var.db_password}" \
        -var "efs_domain=${aws_efs_file_system.wordpress_efs.dns_name}" \
        -var "rds_domain=${aws_db_instance.wordpress.address}" \
        al2023-wp-ami.pkr.hcl
    EOT
  }

  # RDS와 EFS 마운트 타겟이 완전히 준비된 후 Packer 빌드 시작
  depends_on = [aws_efs_mount_target.efs_mount, aws_db_instance.wordpress]
}

# Packer가 빌드한 WordPress AMI를 동적으로 조회 (하드코딩 방지)
# depends_on을 사용해 Packer 빌드 완료 후에 AMI를 검색
data "aws_ami" "wordpress" {
  most_recent = true  # 가장 최근에 빌드된 AMI를 선택
  owners      = ["self"] # 내 계정에서 빌드한 AMI만 검색

  filter {
    name   = "name"
    values = ["wordpress-al2023-*"] # Packer가 생성한 AMI 이름 패턴으로 필터링
  }

  depends_on = [terraform_data.packer_build] # Packer 빌드가 끝난 후 AMI 조회
}

