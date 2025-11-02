# main.tf

# Terraform 설정 및 AWS provider 설정
terraform {
  required_version = ">= 1.13.4" # Terraform 최소 요구 버전
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 프로바이더의 소스 지정
      version = ">= 6.19.0"     # 5.73 버전 이상의 AWS 프로바이더 사용
    }
  }
}

provider "aws" {
  region  = var.aws_region  # AWS 리전 설정
  profile = var.aws_profile # AWS CLI 프로필 설정
}

# EC2 인스턴스 생성
resource "aws_instance" "my_ec2" {
  ami           = data.aws_ami.al2023.id # 사용할 AMI ID
  instance_type = var.instance_type      # 인스턴스 유형 설정 (예: t2.micro)

  tags = {
    Name        = "MyEC2Instance" # 인스턴스의 이름 태그
    Environment = var.environment # 배포 환경 태그 (예: dev, prod)
  }
}


# EC2 인스턴스에 사용할 AMI ID
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
