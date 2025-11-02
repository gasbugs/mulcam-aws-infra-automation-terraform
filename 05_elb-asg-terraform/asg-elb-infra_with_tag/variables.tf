variable "aws_region" {
  description = "AWS 리전"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI 프로파일"
  type        = string
}

# 퍼블릭 키 경로
variable "pub_key_file_path" {
  description = "value"
  type        = string
}

# 인스턴스 타입을 변수로 정의 (필요시 변경 가능)
variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
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
