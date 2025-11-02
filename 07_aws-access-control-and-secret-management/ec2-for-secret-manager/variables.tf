variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
}

variable "aws_profile" {
  description = "AWS profile for all resources"
  type        = string
}


# EC2 정보를 입력
# 키 페어가 저장될 경로를 입력받기 위한 변수
variable "key_path" {
  description = "키 페어가 저장될 경로 (public key)"
  type        = string
}

# secret_arn 정보 입력
variable "secret_arn" {
  description = "secret_arn 정보 입력"
  type        = string
}
