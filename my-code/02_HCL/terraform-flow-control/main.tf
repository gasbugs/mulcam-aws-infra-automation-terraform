# Terraform 설정 및 AWS Provider 설정
terraform {
  required_version = ">= 1.0.0"
}

provider "aws" {
  region  = "us-east-1"
  profile = "my-profile"
}

# 예시2: 동적인 값 할당
locals {
  instance_type = var.environment == "prod" ? "m5.large" : "t3.micro"
}

# 예시4: 맵을 통한 조건 값 선택
locals {
  ami_map = {
    "us-east-1" = "ami-01b14b7ad41e17ba4"
    "us-west-2" = "ami-yyyyyyyyyyyyyyyyy"
  }
  selected_ami = local.ami_map[var.region != "" ? var.region : "us-east-1"]
}

# EC2 인스턴스 생성
resource "aws_instance" "example" {
  ami           = local.selected_ami
  instance_type = local.instance_type

  monitoring = var.enable_monitoring ? true : false
  # 첫 부팅 시 실행할 스크립트 명시 
  user_data = var.custom_user_data != "" ? var.custom_user_data : null

  tags = {
    Name = "ExampleInstance"
  }
}

# 예시3: 조건에 따른 리소스 생성 제어 (S3)
resource "aws_s3_bucket" "example" {
  count  = var.create_bucket ? 1 : 0
  bucket = "my-nick-20260408" # 이 이름은 전세계에서 고유해야 한다. 
}

