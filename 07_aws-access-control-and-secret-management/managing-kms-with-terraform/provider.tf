# AWS 프로바이더 설정 — KMS 키, EC2, S3 등 AWS 리소스를 관리하는 설정 블록
terraform {
  required_version = ">= 1.13.4"
  required_providers {
    # AWS 서비스를 생성·관리하는 공식 프로바이더
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # SSH 키 쌍을 Terraform 내부에서 자동 생성하는 프로바이더
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # 생성된 프라이빗 키를 로컬 파일로 저장하는 프로바이더
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    # 고유한 이름 생성을 위한 랜덤 값 프로바이더
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# 실제 AWS 연결 설정
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}
