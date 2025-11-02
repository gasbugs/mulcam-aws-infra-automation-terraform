# main.tf

# Terraform 설정 및 AWS provider 설정
terraform {
  required_version = ">= 1.13.4" # Terraform 최소 요구 버전
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 프로바이더의 소스 지정
      version = ">= 6.19.0"     # 6.19 버전 이상의 AWS 프로바이더 사용
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
  owners      = ["099720109477"] # Canonical의 공식 AWS 계정 ID (주석 처리)

  filter {
    name   = "name"                                                          # 이름 필터 설정
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"] # Ubuntu 24.04 AMI 검색
  }

  filter {
    name   = "architecture" # 아키텍처 필터 설정
    values = ["x86_64"]     # 64비트 아키텍처
  }
}

# 부트스트랩 스크립트를 로컬 변수로 정의 (Nginx 설치)
# locals {
#   bootstrap_script = <<-EOT
#     #!/bin/bash
#     yum install -y nginx
#     systemctl start nginx
#     echo "Hello, Nginx!" > /usr/share/nginx/html/index.html
#   EOT
# }

# 부트스트랩 스크립트를 로컬 변수로 정의 (Httpd 설치)
locals {
  bootstrap_script = <<-EOT
    #!/bin/bash
    yum install -y httpd
    systemctl start httpd
    echo "Hello, Httpd!" > /var/www/html/index.html
  EOT
}

# 부트스트랩 스크립트가 변경될 때마다 null_resource를 실행
resource "null_resource" "trigger_bootstrap_change" {
  triggers = {
    bootstrap_script = local.bootstrap_script
  }
}

# EC2 인스턴스 생성
resource "aws_instance" "my_ec2" {
  # 사용할 AMI ID - AMI ID 변경 시 replace 업데이트됨
  ami           = true ? data.aws_ami.al2023.id : data.aws_ami.ubuntu.id
  instance_type = "t2.micro" # 인스턴스 유형 설정 - in-place 업데이트됨
  # instance_type = "c5.large"

  # 태그 이름 - in-place 업데이트됨
  tags = {
    Name        = "MyEC2Instance" # 인스턴스의 이름 태그
    Environment = "dev"           # 배포 환경 태그 (예: dev, prod)
  }

  # 사용할 key 이름 - replace 업데이트됨
  key_name = aws_key_pair.my_key_pair.key_name

  # 부트스트랩 스크립트를 user_data에 적용 - in-place 업데이트
  user_data = local.bootstrap_script

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

# 공개 키 파일 읽기
data "local_file" "public_key" {
  filename = pathexpand("~/.ssh/my-key.pub") # 로컬 공개 키 파일 경로 설정
}

# 랜덤 문자열을 포함한 Key Pair 이름 생성
resource "aws_key_pair" "my_key_pair" {
  key_name   = "my-key-${random_string.key_name_suffix.result}" # 랜덤한 이름 생성
  public_key = data.local_file.public_key.content               # 공개 키 설정

  tags = {
    Name = "MyKeyPair-${random_string.key_name_suffix.result}" # Key Pair 이름 태그
  }
}
