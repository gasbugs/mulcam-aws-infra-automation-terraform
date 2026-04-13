terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    # AWS 리소스를 생성·관리하는 공식 프로바이더
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # RSA 키 쌍 생성용 프로바이더 — EC2 SSH 접속 키를 Terraform 내에서 직접 생성
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # 프라이빗 키를 로컬 .pem 파일로 저장하는 프로바이더
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}
