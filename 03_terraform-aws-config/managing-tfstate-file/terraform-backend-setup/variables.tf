# variables.tf

# AWS 리전 설정
variable "aws_region" {
  description = "AWS 리소스를 배포할 리전" # 리전 설명
  type        = string            # 문자열 타입
  default     = "us-east-1"       # 기본값: us-east-1
}

# 사용할 AWS CLI 프로필
variable "aws_profile" {
  description = "사용할 AWS CLI 프로필" # 프로필 설명
  type        = string            # 문자열 타입
  default     = "my-profile"      # 기본값: my-profile
}

# 배포 환경 설정 (예: dev, staging, prod)
variable "environment" {
  description = "배포 환경 설정 (예: dev, staging, prod)" # 환경 설명
  type        = string                             # 문자열 타입
  default     = "dev"                              # 기본값: dev
}

# S3 버킷 이름 (Terraform 상태 파일 저장용)
variable "s3_bucket_name" {
  description = "Terraform 상태 파일을 저장할 S3 버킷 이름"      # S3 버킷 설명
  type        = string                               # 문자열 타입
  default     = "my-terraform-state-bucket-nickname" # 기본값: my-terraform-state-bucket-gasbugs
}

# DynamoDB 테이블 이름 (상태 잠금용)
variable "dynamodb_table_name" {
  description = "Terraform 상태 잠금에 사용할 DynamoDB 테이블 이름" # DynamoDB 테이블 설명
  type        = string                                 # 문자열 타입
  default     = "terraform-state-lock-nickname"        # 기본값: terraform-state-lock-gasbugs
}
