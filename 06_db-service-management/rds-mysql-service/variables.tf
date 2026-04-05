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

#######################################
# RDS에 대한 변수

variable "allowed_cidr" {
  description = "The CIDR block allowed to access the RDS instance"
  type        = string

  # CIDR 형식 유효성 검사 (예: 10.0.0.0/16)
  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0))
    error_message = "allowed_cidr은 유효한 CIDR 형식이어야 합니다 (예: 10.0.0.0/16)."
  }
}

variable "db_allocated_storage" {
  description = "The allocated storage size for the RDS instance in GB"
  type        = number
  default     = 20

  validation {
    condition     = var.db_allocated_storage >= 20 && var.db_allocated_storage <= 65536
    error_message = "db_allocated_storage는 20 ~ 65536 GB 사이여야 합니다."
  }
}

variable "db_engine_version" {
  # null(기본값): data.aws_rds_engine_version.mysql 에서 AWS 기본 최신 버전 자동 조회
  # 특정 버전 고정: terraform.tfvars 에 db_engine_version = "8.0.36" 처럼 지정
  # 사용 가능한 버전 목록 확인: aws rds describe-db-engine-versions --engine mysql
  description = "MySQL 엔진 버전 (null이면 data 소스에서 AWS 기본 최신 버전을 자동 조회)"
  type        = string
  default     = null
}

variable "db_instance_class" {
  description = "The instance class of the RDS instance"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "The name of the database"
  type        = string
}

variable "db_username" {
  description = "The master username for the RDS instance"
  type        = string
}

variable "db_password" {
  description = "The master password for the RDS instance"
  type        = string
  sensitive   = true
}

variable "db_parameter_group_name" {
  # null(기본값): 엔진 버전에서 자동 결정 (예: MySQL 8.4.x → "default.mysql8.4")
  # 직접 지정: terraform.tfvars에 db_parameter_group_name = "default.mysql8.0" 처럼 설정
  description = "DB 파라미터 그룹 이름 (null이면 엔진 버전에 맞게 자동 결정)"
  type        = string
  default     = null
}

variable "db_multi_az" {
  description = "Whether the RDS instance is multi-AZ"
  type        = bool
  default     = false
}


#######################################
# EC2에 대한 변수
variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "instance_name" {
  description = "Name tag for the EC2 instance"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "SSH 접근을 허용할 CIDR 블록 (0.0.0.0/0은 모든 IP 허용으로 보안에 취약)"
  type        = string
  default     = "0.0.0.0/0" # 실무에서는 관리자 IP 또는 VPN CIDR로 제한 권장

  validation {
    condition     = can(cidrhost(var.allowed_ssh_cidr, 0))
    error_message = "allowed_ssh_cidr은 유효한 CIDR 형식이어야 합니다 (예: 203.0.113.0/24)."
  }
}
