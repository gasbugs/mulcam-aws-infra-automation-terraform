# 입력 변수 정의 — 코드를 재사용하기 위해 외부에서 값을 받는 설정

# AWS 연결 기본 설정 변수
variable "aws_region" {
  description = "AWS 리소스를 생성할 리전 (예: us-east-1)"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI에 설정된 자격증명 프로파일 이름"
  type        = string
  default     = "my-profile"
}

variable "environment" {
  description = "배포 환경 구분자 (예: dev, staging, prod)"
  type        = string
  default     = "dev"
}

# IAM 유저 관련 변수
variable "user_name" {
  description = "생성할 IAM 사용자의 이름"
  type        = string
  default     = "example_user"
}

variable "s3_policy_file" {
  description = "S3 읽기 전용 정책이 담긴 JSON 파일 경로"
  type        = string
  default     = "s3-readonly-policy.json"
}
