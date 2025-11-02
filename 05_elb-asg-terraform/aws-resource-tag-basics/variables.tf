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

# EC2 인스턴스의 타입을 지정하는 변수
variable "instance_type" {
  description = "Instance type for the EC2 instance"
  type        = string
  default     = "t2.micro"
}

# EC2 인스턴스의 Name 태그
variable "instance_name" {
  description = "Name tag for the EC2 instance"
  type        = string
  default     = "WebServer-Prod"
}

# 리소스와 연관된 프로젝트 이름을 지정하는 변수
variable "project" {
  description = "Project name associated with this resource"
  type        = string
  default     = "MarketingApp"
}

# 해당 리소스와 연관된 비용 센터를 지정하는 변수
variable "cost_center" {
  description = "Cost Center associated with the resource"
  type        = string
  default     = "1234"
}
