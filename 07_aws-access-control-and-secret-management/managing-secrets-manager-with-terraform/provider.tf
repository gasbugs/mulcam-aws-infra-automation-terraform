# AWS 프로바이더 설정 — Secrets Manager와 KMS, Lambda 등을 관리하는 설정 블록
terraform {
  required_version = ">= 1.13.4"
  required_providers {
    # AWS 서비스를 생성·관리하는 공식 프로바이더
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # 랜덤 비밀번호 및 고유 이름 생성용 프로바이더
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    # RSA 키 쌍 생성용 프로바이더 — EC2 SSH 접속 키를 Terraform 내에서 직접 생성
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # 로컬 파일 저장용 프로바이더 — 생성된 프라이빗 키를 .pem 파일로 저장
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

# 실제 AWS 연결 설정 — 어느 리전에, 어떤 자격증명으로 접속할지 정의
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}
