# 입력 변수 정의 — KMS + Secrets Manager + Aurora 통합 실습에 필요한 설정 값

# AWS 리소스를 생성할 리전을 지정하는 변수
variable "aws_region" {
  description = "AWS 리소스를 생성할 리전 (예: us-east-1)"
  type        = string
  default     = "us-east-1"
}

# AWS CLI에 설정된 자격증명 프로파일 이름
variable "aws_profile" {
  description = "AWS CLI에 설정된 자격증명 프로파일 이름"
  type        = string
  default     = "my-profile"
}

# 배포 환경 구분자 (예: dev, staging, prod)
variable "environment" {
  description = "배포 환경 구분자 (예: dev, staging, prod)"
  type        = string
  default     = "dev"
}

# EC2 인스턴스의 소유자 또는 담당 팀을 나타내는 변수
variable "owner" {
  description = "EC2 인스턴스의 소유자 또는 담당 팀"
  type        = string
  default     = "TeamA"
}

########################################
# 시크릿 정보 구성
# KMS 키의 설명을 입력받기 위한 변수
variable "kms_description" {
  description = "KMS 키의 설명 — Aurora DB 데이터 암호화에 사용할 키"
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
  description = "Secrets Manager에 저장할 시크릿의 설명"
  type        = string
  default     = "Secret encrypted with a custom KMS key"
}

# Lambda 함수의 이름
variable "lambda_function_name" {
  description = "시크릿 자동 교체에 사용할 Lambda 함수의 이름"
  type        = string
  default     = "rotate-secret-function"
}

#######################################
# RDS에 대한 변수
variable "cluster_identifier" {
  description = "Aurora 클러스터를 식별하는 고유 이름"
  type        = string
}

variable "db_engine_version" {
  description = "Aurora MySQL 엔진 버전 (예: 8.0.mysql_aurora.3.10.1)"
  type        = string
  default     = "8.0.mysql_aurora.3.10.1"
}

variable "db_username" {
  description = "Aurora 클러스터의 관리자(마스터) 계정 이름"
  type        = string
}

variable "db_instance_class" {
  description = "Aurora 인스턴스의 컴퓨팅 사양 (예: db.r5.large)"
  type        = string
  default     = "db.r5.large"
}

variable "allowed_cidr" {
  description = "Aurora DB에 접근을 허용할 CIDR 블록 (예: 10.0.0.0/16)"
  type        = string
}

#######################################
# VPC에 대한 변수
variable "vpc_name" {
  description = "생성할 VPC의 이름"
  type        = string
  default     = "my-vpc"
}

variable "vpc_cidr" {
  description = "VPC의 IP 주소 범위 (CIDR 표기법, 예: 10.0.0.0/16)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "인터넷과 통신 가능한 퍼블릭 서브넷 CIDR 목록"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnets" {
  description = "인터넷과 직접 통신하지 않는 프라이빗 서브넷 CIDR 목록"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "availability_zones" {
  description = "서브넷을 배치할 가용 영역 목록 (예: us-east-1a, us-east-1b)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}
