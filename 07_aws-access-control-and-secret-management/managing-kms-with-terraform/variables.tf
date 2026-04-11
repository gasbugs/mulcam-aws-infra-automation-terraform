# 입력 변수 정의 — KMS 키 관리 실습에 필요한 설정 값

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

variable "bucket_name" {
  description = "생성할 S3 버킷의 기본 이름 (뒤에 랜덤 숫자가 붙어 고유하게 생성됨)"
  type        = string
  default     = "my-example-secure-bucket"
}

variable "ami_id" {
  description = "EC2 인스턴스에 사용할 AMI ID (운영체제 이미지)"
  type        = string
  default     = "ami-0c94855ba95c71c99" # Amazon Linux 2 AMI (us-east-1 리전 기준)
}
