# AWS 프로바이더 설정 — Terraform이 어떤 클라우드를 사용할지 지정하는 블록
terraform {
  required_version = ">= 1.13.4"
  required_providers {
    # AWS 서비스를 생성·관리하는 공식 프로바이더
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# 실제 AWS 연결 설정 — 어느 리전에, 어떤 자격증명으로 접속할지 정의
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}
