# main.tf

# Terraform 설정 및 AWS provider 설정
terraform {
  required_version = ">= 1.13.4" # Terraform 최소 요구 버전
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 프로바이더의 소스 지정
      version = "~> 6.0"        # 6.x.x 버전 이상의 AWS 프로바이더 사용
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region  # AWS 리전 설정
  profile = var.aws_profile # AWS CLI 프로필 설정
}

# Amazon Linux 2023 AMI ID를 가져오는 data 블록
data "aws_ami" "al2023" {
  most_recent = true       # 최신 버전의 AMI 가져오기
  owners      = ["amazon"] # Amazon에서 제공하는 공식 AMI 사용

  filter {
    name   = "name"           # 이름 필터 설정
    values = ["al2023-ami-*"] # Amazon Linux 2023 AMI 검색
  }

  filter {
    name   = "architecture" # 아키텍처 필터 설정
    values = ["x86_64"]     # 64비트 아키텍처
  }
}

# Ubuntu 24.04 AMI ID를 가져오는 data 블록 (출시 후 사용 가능)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical의 공식 AWS 계정 ID

  filter {
    name   = "name"                                                           # 이름 필터 설정
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"] # Ubuntu 24.04 AMI 검색
  }

  filter {
    name   = "architecture" # 아키텍처 필터 설정
    values = ["x86_64"]     # 64비트 아키텍처
  }
}

# 선택된 웹 서버에 맞는 부트스트랩 스크립트 경로를 로컬 변수로 정의
# [replace 업데이트 실습] var.web_server를 "httpd" ↔ "nginx" 로 변경하면 인스턴스가 replace됨
#   scripts/bootstrap-httpd.sh  ← httpd 설치 스크립트
#   scripts/bootstrap-nginx.sh  ← nginx 설치 스크립트
locals {
  bootstrap_script_path = "${path.module}/scripts/bootstrap-${var.web_server}.sh"
}

# 부트스트랩 스크립트 파일이 변경될 때마다 null_resource를 실행
resource "null_resource" "trigger_bootstrap_change" {
  triggers = {
    bootstrap_script = filesha256(local.bootstrap_script_path)
  }
}

# HTTP(80) 포트를 허용하는 보안 그룹
resource "aws_security_group" "web_sg" {
  name        = "${var.instance_name}-web-sg"
  description = "Allow HTTP inbound traffic"

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.instance_name}-web-sg"
    Environment = var.environment
  }
}

# EC2 인스턴스 생성
resource "aws_instance" "my_ec2" {
  # 사용할 AMI ID - AMI ID 변경 시 replace 업데이트됨
  ami           = var.use_amazon_linux ? data.aws_ami.al2023.id : data.aws_ami.ubuntu.id
  instance_type = var.instance_type # 인스턴스 유형 설정 - in-place 업데이트됨

  # 태그 이름 - in-place 업데이트됨
  tags = {
    Name        = var.instance_name  # 인스턴스의 이름 태그
    Environment = var.environment    # 배포 환경 태그 (예: dev, prod)
  }

  # 사용할 key 이름 - replace 업데이트됨
  key_name = aws_key_pair.my_key_pair.key_name

  # 보안 그룹 연결 - replace 업데이트됨
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  # 부트스트랩 스크립트를 user_data에 적용 - replace 업데이트
  user_data = file(local.bootstrap_script_path)

  # 부트스트랩 스크립트 변경 시 EC2 인스턴스가 리플레이스되도록 설정
  # 강제 replace를 구성하지 않으면 재시작만 되면서 user_data 설정이 충돌됨
  lifecycle {
    replace_triggered_by = [null_resource.trigger_bootstrap_change]
  }
}

# 랜덤한 문자열 생성 (Key Pair 이름 구성에 사용)
resource "random_string" "key_name_suffix" {
  length  = 8     # 랜덤 문자열 길이 설정
  special = false # 특수 문자 제외
  upper   = false # 대문자 제외
}

# RSA 키 쌍 생성 (TLS 프로바이더 사용)
resource "tls_private_key" "my_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# 랜덤 문자열을 포함한 Key Pair 이름 생성
resource "aws_key_pair" "my_key_pair" {
  key_name   = "my-key-${random_string.key_name_suffix.result}"   # 랜덤한 이름 생성
  public_key = tls_private_key.my_key.public_key_openssh          # TLS로 생성한 공개 키 사용

  tags = {
    Name = "MyKeyPair-${random_string.key_name_suffix.result}" # Key Pair 이름 태그
  }
}
