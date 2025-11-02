##########################################################################
# 프로바이더 설정
##########################################################################
# Terraform 설정 및 AWS provider 설정
terraform {
  required_version = ">=1.13.4" # Terraform 최소 요구 버전
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

##########################################################################
# EC2 설정
##########################################################################
# Ubuntu 24.04 AMI ID를 가져오는 data 블록 
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical의 공식 AWS 계정 ID

  filter {
    name   = "name"                                                          # 이름 필터 설정
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"] # Ubuntu 24.04 AMI 검색
  }

  filter {
    name   = "architecture" # 아키텍처 필터 설정
    values = ["x86_64"]     # 64비트 아키텍처
  }
}


# EC2 인스턴스 생성
resource "aws_instance" "my_ec2" {
  count = 3
  ami   = data.aws_ami.ubuntu.id
  #instance_type = "t2.micro"
  instance_type               = "t2.small"
  key_name                    = aws_key_pair.my_key_pair.key_name
  subnet_id                   = module.my_vpc.public_subnets[count.index]
  vpc_security_group_ids      = [aws_security_group.my_sg.id]
  associate_public_ip_address = true

  tags = {
    Name = "MyFirstInstance-${count.index + 1}" # 인스턴스의 이름 태그
  }

  lifecycle {
    create_before_destroy = true
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


##########################################################################
# VPC 설정
##########################################################################
locals {
  aws_zone_mapping = {
    "us-east-1" = ["a", "b", "c"]
  }
  azs = [for az in local.aws_zone_mapping[var.aws_region] : "${var.aws_region}${az}"]
}

module "my_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name = "my-vpc"
  cidr = "10.0.0.0/16"

  azs             = local.azs
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = false
  single_nat_gateway = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

resource "aws_security_group" "my_sg" {
  vpc_id = module.my_vpc.vpc_id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }
}
