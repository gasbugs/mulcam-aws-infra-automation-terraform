# provider.tf
# Terraform과 AWS를 사용하기 위한 기본 설정 파일입니다.
# 어떤 버전의 도구를 사용할지, 어느 AWS 계정/리전에 배포할지를 지정합니다.

terraform {
  # Terraform 프로그램 자체의 최소 버전을 지정합니다.
  # 이보다 낮은 버전에서는 실행되지 않아 예상치 못한 오류를 방지합니다.
  required_version = ">= 1.13.4"

  required_providers {
    # AWS 리소스(S3, CloudFront 등)를 만들기 위한 플러그인입니다.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # 6.x 버전대를 사용하되 7.0 이상은 허용하지 않아 호환성을 유지합니다.
    }

    # [추가] 무작위 숫자/문자열을 생성하는 플러그인입니다.
    # random_integer 리소스를 사용하므로 반드시 명시해야 버전 잠금이 가능합니다.
    # 선언하지 않으면 Terraform이 임의로 최신 버전을 내려받아 예상치 못한 동작이 생길 수 있습니다.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# AWS 프로바이더 설정
# 실제로 AWS에 연결할 때 사용할 리전(지역)과 인증 프로파일을 지정합니다.
provider "aws" {
  region  = var.aws_region  # 리소스를 생성할 AWS 지역 (예: us-east-1 = 미국 동부)
  profile = var.aws_profile # 내 컴퓨터 ~/.aws/config에 저장된 인증 정보 이름
}
