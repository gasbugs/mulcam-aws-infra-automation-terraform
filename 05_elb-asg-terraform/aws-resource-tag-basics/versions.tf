# Terraform 및 AWS 프로바이더 버전 제약 설정
terraform {
  required_version = ">= 1.13.4" # Terraform 최소 요구 버전
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 프로바이더의 소스 지정
      version = "~> 6.0"        # 6.x.x 버전대의 AWS 프로바이더 사용
    }
  }
}
