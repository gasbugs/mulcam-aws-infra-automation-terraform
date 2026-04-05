# Terraform 및 프로바이더 버전 요구사항 정의 (provider.tf와 분리하여 관리)
terraform {
  required_version = ">= 1.13.4" # Terraform 최소 요구 버전
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 리소스를 관리하는 프로바이더
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random" # 랜덤 값 생성에 사용하는 프로바이더 (키 페어 이름 중복 방지)
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls" # TLS 인증서 및 SSH 키 쌍 생성에 사용하는 프로바이더
      version = "~> 4.0"
    }
  }
}
