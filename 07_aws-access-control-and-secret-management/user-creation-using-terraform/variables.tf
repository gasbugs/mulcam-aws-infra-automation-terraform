variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
}

variable "aws_profile" {
  description = "AWS profile for all resources"
  type        = string
}



# IAM 유저 이름 변수
variable "ec2_user_name" {
  description = "Name of the IAM user for EC2 management"
  type        = string
  default     = "ec2_user"
}

# IAM 그룹 이름 변수
variable "ec2_group_name" {
  description = "Name of the IAM group for EC2 management"
  type        = string
  default     = "ec2-managers"
}
