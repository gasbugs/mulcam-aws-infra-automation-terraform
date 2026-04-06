# AWS에서 리소스를 배포할 리전을 지정하는 변수 (예: us-east-1)
variable "aws_region" {
  description = "AWS 리전"
  type        = string
}

# AWS CLI를 사용할 때 참조할 프로파일 이름을 지정하는 변수
variable "aws_profile" {
  description = "AWS CLI 프로파일"
  type        = string
}

# 리소스에 공통으로 적용할 소유자 태그
variable "owner" {
  description = "리소스 소유자 또는 담당 팀"
  type        = string
  default     = "TeamA"
}

# 배포 환경을 나타내는 변수 (예: Production, Staging, Development)
variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "Production"
}

#######################################
# VPC에 대한 변수

variable "vpc_name" {
  description = "VPC의 이름"
  type        = string
  default     = "my-vpc"
}

variable "vpc_cidr" {
  description = "VPC에 할당할 CIDR 블록 (예: 10.0.0.0/16)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "퍼블릭 서브넷 CIDR 블록 목록"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnets" {
  description = "프라이빗 서브넷 CIDR 블록 목록"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "availability_zones" {
  description = "서브넷을 배포할 가용 영역 목록"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

#######################################
# RDS에 대한 변수

variable "cluster_identifier" {
  description = "Aurora 클러스터 식별자"
  type        = string
  default     = "my-rds"
}

variable "db_username" {
  description = "Aurora 클러스터 마스터 사용자 이름"
  type        = string
  default     = "admin"
}

variable "db_password" {
  description = "Aurora 클러스터 마스터 비밀번호"
  type        = string
  sensitive   = true
  default     = "securepassword123!" # 민감 정보, 환경 변수로도 관리 가능
}

variable "db_instance_class" {
  description = "Aurora 클러스터 인스턴스 클래스"
  type        = string
  default     = "db.r8g.large"
}

variable "allowed_cidr" {
  description = "RDS 접근을 허용할 CIDR 블록"
  type        = string
  default     = "10.0.0.0/16" # VPC 내부 트래픽만 허용
}
