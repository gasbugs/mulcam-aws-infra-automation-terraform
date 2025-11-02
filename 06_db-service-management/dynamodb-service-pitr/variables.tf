#######################################
# 프로바이더 및 환경 정보
variable "aws_region" {
  description = "AWS 리전"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI 프로파일"
  type        = string
}

variable "environment" {
  description = "The environment of the RDS instance (e.g., Production, Staging)"
  type        = string
  default     = "Production"
}

variable "owner" {
  description = "이 리소스를 관리하는 담당자"
  type        = string
  default     = "TeamA"
}

#######################################
# DynamoDB 변수
variable "table_name" {
  description = "The name of the DynamoDB table"
  type        = string
  default     = "Users"
}

variable "read_capacity" {
  description = "The read capacity units for the DynamoDB table"
  type        = number
  default     = 5
}

variable "write_capacity" {
  description = "The write capacity units for the DynamoDB table"
  type        = number
  default     = 5
}

variable "project" {
  description = "The project tag for the DynamoDB table"
  type        = string
  default     = "UserManagement"
}
