# variables.tf

# AWS 리전 설정
variable "aws_region" {
  description = "리소스를 배포할 AWS 리전"
  type        = string
  default     = "us-east-1"
}

# AWS 프로파일 설정
variable "aws_profile" {
  description = "인증에 사용할 AWS CLI 프로파일"
  type        = string
  default     = "my-profile"
}
