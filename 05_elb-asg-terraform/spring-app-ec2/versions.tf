terraform {
  required_version = ">= 1.13.4"
  required_providers {
    # AWS 리소스 생성에 사용하는 공식 프로바이더
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Packer 실행 등 로컬 명령을 Terraform 수명주기에 연결하기 위한 프로바이더
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}
