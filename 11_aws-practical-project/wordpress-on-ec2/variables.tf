# AWS 리소스를 배포할 리전 설정
variable "aws_region" {
  description = "AWS region where resources will be deployed (e.g. us-east-1)"
  default     = "us-east-1"
}

# RDS 데이터베이스 관리자 계정 이름
variable "db_username" {
  description = "RDS database administrator username"
  type        = string
}

# RDS 데이터베이스 관리자 비밀번호 (보안상 민감 정보로 처리)
variable "db_password" {
  description = "RDS database administrator password (marked sensitive - will not appear in logs or outputs)"
  type        = string
  sensitive   = true # 비밀번호는 로그나 출력에 노출되지 않도록 민감 정보로 처리
}
