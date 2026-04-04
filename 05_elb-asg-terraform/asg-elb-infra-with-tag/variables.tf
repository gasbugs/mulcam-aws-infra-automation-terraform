variable "aws_region" {
  description = "AWS 리전"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI 프로파일"
  type        = string
}

# 인스턴스 타입을 변수로 정의 (필요시 변경 가능)
variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

# 원하는 오토 스케일링 그룹의 크기를 정의
variable "desired_capacity" {
  description = "Desired number of instances in the Auto Scaling group"
  type        = number
  default     = 2
}

variable "max_size" {
  description = "Maximum number of instances in the Auto Scaling group"
  type        = number
  default     = 4
}

variable "min_size" {
  description = "Minimum number of instances in the Auto Scaling group"
  type        = number
  default     = 2
}

# 리소스 태그에 사용할 공통 값들
variable "project" {
  description = "프로젝트 이름 (태그에 사용)"
  type        = string
  default     = "MarketingApp"
}

variable "environment" {
  description = "배포 환경 이름 (예: Production, Staging, Dev)"
  type        = string
  default     = "Production"
}

variable "owner" {
  description = "리소스 소유 팀 이름 (비용 추적 및 책임 소재 식별용)"
  type        = string
  default     = "TeamA"
}

# AWS Cost Allocation Tags와 연동하여 부서별 비용 정산(Chargeback)에 사용되는 비용 센터 코드
variable "cost_center" {
  description = "비용 센터 코드 (AWS Cost Allocation Tags와 연동하여 부서별 비용 정산에 사용)"
  type        = string
  default     = "CC-001"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "List of public subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnets" {
  description = "List of private subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}
