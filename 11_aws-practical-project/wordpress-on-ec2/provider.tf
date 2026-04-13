# Terraform 및 AWS 프로바이더 버전 설정
terraform {
  # 실제 릴리스된 버전 기준으로 최소 요구 버전 설정 (1.9.0부터 terraform_data 리소스 지원)
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 프로바이더의 소스 지정
      version = "~> 6.0"        # AWS 프로바이더 6.x 버전 사용
    }
  }
}

# AWS 프로바이더 설정
provider "aws" {
  region  = var.aws_region # 리소스를 배포할 AWS 리전
  profile = "my-profile"   # 인증에 사용할 AWS CLI 프로파일
}
