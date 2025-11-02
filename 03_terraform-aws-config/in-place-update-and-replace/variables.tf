# variables.tf

# AWS 리전 설정
variable "aws_region" {
  description = "리소스를 배포할 AWS 리전" # 리전 설명
  type        = string            # 문자열 타입
  default     = "us-east-1"       # 기본값: us-east-1
}

# 사용할 AWS CLI 프로필 설정
variable "aws_profile" {
  description = "AWS CLI에서 사용할 프로필" # 프로필 설명
  type        = string              # 문자열 타입
  default     = "my-profile"        # 기본값: my-profile
}

# 배포 환경 설정 (예: dev, staging, prod)
variable "environment" {
  description = "배포 환경 설정 (예: dev, staging, prod)" # 환경 설명
  type        = string                             # 문자열 타입
  default     = "prod"                             # 기본값: prod, 프로덕션 환경을 나타냄
}
