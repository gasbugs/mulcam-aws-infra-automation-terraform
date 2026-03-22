terraform {
  required_version = ">= 1.0.0" # Terraform 최소 요구 버전
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 프로바이더의 소스 지정
      version = "~> 6.0"     # 6.x.x 버전 이상의 AWS 프로바이더 사용 이상의 AWS 프로바이더 사용
    }
  }
}
