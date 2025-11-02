# Terraform 설정 및 AWS provider 설정
terraform {
  required_version = ">= 1.13.4" # Terraform 최소 요구 버전
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 프로바이더 소스 지정
      version = ">= 6.19.0"     # 5.73 버전 이상의 AWS 프로바이더 사용
    }
  }
}

provider "aws" {
  region  = var.aws_region  # 리소스를 배포할 AWS 리전 설정
  profile = var.aws_profile # 사용할 AWS CLI 프로파일 설정
}

# S3 버킷을 사용하여 Terraform 상태 관리
resource "aws_s3_bucket" "terraform_state" {
  bucket = var.s3_bucket_name # 상태 파일을 저장할 S3 버킷 이름

  tags = {
    Name        = "TerraformStateBucket" # S3 버킷 이름 태그 지정
    Environment = var.environment        # 환경 태그 추가 (예: dev, prod)
  }
}

# S3 버킷 버전 관리 설정
resource "aws_s3_bucket_versioning" "example" {
  bucket = aws_s3_bucket.terraform_state.id # 버전 관리 활성화할 S3 버킷 ID

  versioning_configuration {
    status = "Enabled" # S3 버킷 버전 관리 활성화
  }
}

# S3 버킷 암호화 설정
resource "aws_s3_bucket_server_side_encryption_configuration" "example" {
  bucket = aws_s3_bucket.terraform_state.id # 암호화를 적용할 S3 버킷 ID

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # 서버 사이드 암호화 알고리즘 설정 (AES256)
    }
  }
}

# DynamoDB 테이블 생성 (잠금 관리를 위한 테이블)
resource "aws_dynamodb_table" "terraform_lock" {
  name         = var.dynamodb_table_name # 잠금 관리를 위한 테이블 이름
  billing_mode = "PAY_PER_REQUEST"       # 사용량 기반 과금 설정
  hash_key     = "LockID"                # 해시 키 설정 (잠금 식별자)

  attribute {
    name = "LockID" # 테이블 해시 키 이름
    type = "S"      # 해시 키 데이터 타입 설정 (문자열)
  }

  tags = {
    Name        = "TerraformStateLockTable" # DynamoDB 테이블 이름 태그
    Environment = var.environment           # 환경 태그 추가
  }
}
