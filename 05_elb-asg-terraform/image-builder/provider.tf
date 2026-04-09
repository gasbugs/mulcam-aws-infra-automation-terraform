##############################################################################
# [provider.tf] Terraform 실행 환경 기본 설정
#
# Terraform이 AWS와 통신하기 위한 가장 기본적인 설정 파일입니다.
# 이 파일에서 정의하는 것:
#   - required_version: Terraform CLI 최소 버전 (>= 1.13.4)
#   - required_providers: AWS 프로바이더 버전 고정 (~> 6.0)
#   - provider "aws": 접속할 리전과 사용할 AWS 프로파일 지정
#   - data "aws_caller_identity": 현재 AWS 계정 ID 조회 (S3 버킷 이름 생성에 사용)
#   - data "aws_region": 현재 리전 정보 조회
##############################################################################

# AWS 프로바이더 설정 — Terraform이 AWS 리소스를 생성·관리하기 위한 기본 연결 정보
terraform {
  required_version = ">= 1.13.4"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# 현재 AWS 계정 ID와 리전 정보 조회 — 버킷 이름 등 유일성 보장에 사용
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
