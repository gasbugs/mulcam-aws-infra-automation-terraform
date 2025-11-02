# AWS 설정 관련 변수
# AWS에서 리소스를 배포할 리전을 지정하는 변수 (예: ap-northeast-2)
variable "aws_region" {
  description = "AWS 리전"
  type        = string
}

# AWS CLI를 사용할 때 참조할 프로파일 이름을 지정하는 변수
variable "aws_profile" {
  description = "AWS CLI 프로파일"
  type        = string
}

# EC2 인스턴스의 소유자 또는 담당 팀을 나타내는 변수
variable "owner" {
  description = "Owner of the EC2 instance"
  type        = string
  default     = "TeamA"
}

# 배포 환경을 나타내는 변수 (예: Production, Staging, Development)
variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "Production"
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

# Lambda 함수의 이름
variable "lambda_function_name" {
  description = "생성할 Lambda 함수의 이름"
  type        = string
  default     = "rotate-secret-function"
}

#############################
# EC2 정보를 입력
# 키 페어가 저장될 경로를 입력받기 위한 변수
variable "key_path" {
  description = "키 페어가 저장될 경로 (public key)"
  type        = string
}

#######################################
# RDS에 대한 변수
variable "cluster_identifier" {
  description = "The identifier for the Aurora cluster"
  type        = string
}

variable "db_engine_version" {
  description = "The version of the Aurora engine"
  type        = string
  default     = "8.0.mysql_aurora.3.10.1" # 예시: MySQL 호환 버전
}

variable "db_username" {
  description = "The master username for the Aurora cluster"
  type        = string
}

variable "db_instance_class" {
  description = "The instance class for the Aurora cluster instances"
  type        = string
  default     = "db.r5.large"
}

variable "allowed_cidr" {
  description = "The CIDR block allowed to access the RDS instance"
  type        = string
}

#######################################
# VPC에 대한 변수
variable "vpc_name" {
  description = "The name of the VPC"
  type        = string
  default     = "my-vpc"
}

variable "vpc_cidr" {
  description = "The CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "A list of CIDR blocks for the public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnets" {
  description = "A list of CIDR blocks for the private subnets"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "availability_zones" {
  description = "A list of availability zones for the subnets"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}
