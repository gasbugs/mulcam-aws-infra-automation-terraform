# 입력 변수 정의 — 코드를 재사용하기 위해 외부에서 값을 받는 설정

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

# IAM 유저 이름 변수
variable "ec2_user_name" {
  description = "EC2 관리를 위해 생성할 IAM 사용자 이름"
  type        = string
  default     = "ec2_user"
}

# IAM 그룹 이름 변수
variable "ec2_group_name" {
  description = "EC2 관리 권한을 묶어 관리할 IAM 그룹 이름"
  type        = string
  default     = "ec2-managers"
}
