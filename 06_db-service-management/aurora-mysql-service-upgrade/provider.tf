# Terraform 및 AWS 프로바이더 버전 설정
terraform {
  required_version = ">= 1.13.4" # Terraform 최소 요구 버전
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 프로바이더의 소스 지정
      version = "~> 6.0"        # 6.x.x 버전대의 AWS 프로바이더 사용
    }
    random = {
      source  = "hashicorp/random" # 랜덤 값 생성 프로바이더 (EC2 키 페어 이름 중복 방지용)
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls" # TLS 키 쌍 생성 프로바이더 (RSA 키 페어 자동 생성용)
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local" # 로컬 파일 생성 프로바이더 (프라이빗 키를 파일로 저장)
      version = "~> 2.0"
    }
  }
}

# AWS 프로바이더 설정
provider "aws" {
  region  = var.aws_region  # 리소스를 배포할 AWS 리전
  profile = var.aws_profile # 인증에 사용할 AWS CLI 프로파일

  default_tags {
    tags = {
      Environment = var.environment
      Owner       = var.owner
    }
  }
}
