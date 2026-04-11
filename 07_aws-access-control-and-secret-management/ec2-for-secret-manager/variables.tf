# 입력 변수 정의 — EC2에서 Secrets Manager 접근 실습에 필요한 설정 값

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

# secret_arn 정보 입력
variable "secret_arn" {
  description = "EC2에서 접근을 허용할 Secrets Manager 시크릿 ARN"
  type        = string
}
