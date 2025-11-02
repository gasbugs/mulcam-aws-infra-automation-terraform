variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
}

variable "aws_profile" {
  description = "AWS profile for all resources"
  type        = string
}

########################################
# 시크릿 정보 구성
# KMS 키의 설명을 입력받기 위한 변수
variable "kms_description" {
  description = "KMS 키의 설명"
  type        = string
  default     = "KMS key for encrypting secrets"
}

# 생성할 시크릿의 이름
variable "secret_name" {
  description = "Secrets Manager에 생성할 시크릿의 이름"
  type        = string
  default     = "my-example-secret"
}

# 생성할 시크릿의 설명
variable "secret_description" {
  description = "시크릿의 설명"
  type        = string
  default     = "Secret encrypted with a custom KMS key"
}

# 시크릿의 초기 값 중 사용자 이름
variable "secret_username" {
  description = "시크릿의 초기 값 중 사용자 이름"
  type        = string
}

# Lambda 함수의 이름
variable "lambda_function_name" {
  description = "생성할 Lambda 함수의 이름"
  type        = string
  default     = "rotate-secret-function"
}
