# 입력 변수 정의 — Secrets Manager 실습에 필요한 설정 값

# AWS 리소스를 배포할 리전 설정
variable "aws_region" {
  description = "AWS 리소스를 생성할 리전 (예: us-east-1)"
  type        = string
  default     = "us-east-1"
}

# AWS CLI 인증 프로파일 이름
variable "aws_profile" {
  description = "AWS CLI에 설정된 자격증명 프로파일 이름"
  type        = string
  default     = "my-profile"
}

# 배포 환경 구분자
variable "environment" {
  description = "배포 환경 구분자 (예: dev, staging, prod)"
  type        = string
  default     = "dev"
}

########################################
# 시크릿 정보 구성
# KMS 키의 설명을 입력받기 위한 변수
variable "kms_description" {
  description = "시크릿 암호화에 사용할 KMS 키의 설명 문자열"
  type        = string
  default     = "KMS key for encrypting secrets"
}

# 생성할 시크릿의 이름
variable "secret_name" {
  description = "Secrets Manager에 생성할 시크릿의 기본 이름 (뒤에 랜덤 숫자가 붙음)"
  type        = string
  default     = "my-example-secret"
}

# 생성할 시크릿의 설명
variable "secret_description" {
  description = "Secrets Manager에 저장되는 시크릿의 용도 설명"
  type        = string
  default     = "Secret encrypted with a custom KMS key"
}

# 시크릿의 초기 값 중 사용자 이름
variable "secret_username" {
  description = "시크릿에 저장할 초기 사용자 이름 (예: admin, dbuser)"
  type        = string
}

# Lambda 함수의 이름
variable "lambda_function_name" {
  description = "시크릿 자동 교체를 수행할 Lambda 함수의 이름"
  type        = string
  default     = "rotate-secret-function"
}
