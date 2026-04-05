# Terraform 및 AWS 프로바이더 버전 설정
terraform {
  required_version = ">= 1.13.4" # Terraform 최소 요구 버전
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 프로바이더의 소스 지정
      version = "~> 6.0"        # 6.x.x 버전 이상의 AWS 프로바이더 사용
    }
    # EC2 모듈의 random_integer 리소스에 필요한 프로바이더
    random = {
      source  = "hashicorp/random" # 무작위 값 생성 프로바이더
      version = "~> 3.0"           # 3.x.x 버전 이상 사용
    }
    # EC2 SSH 키를 Terraform이 직접 생성할 때 사용하는 프로바이더
    tls = {
      source  = "hashicorp/tls" # RSA/ECDSA 키 쌍 생성 프로바이더
      version = "~> 4.0"
    }
    # tls_private_key로 생성된 프라이빗 키를 로컬 파일로 저장할 때 사용
    local = {
      source  = "hashicorp/local" # 로컬 파일 생성 프로바이더
      version = "~> 2.0"
    }
  }
}

# AWS 프로바이더 설정
provider "aws" {
  region  = var.aws_region  # 리소스를 배포할 AWS 리전
  profile = var.aws_profile # 인증에 사용할 AWS CLI 프로파일
}
