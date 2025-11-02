variable "aws_region" {
  description = "리소스를 배포할 AWS 리전"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "사용할 AWS CLI 프로파일"
  type        = string
  default     = "my-profile"
}

variable "vpc_cidr_block" {
  description = "VPC에 할당할 CIDR 블록"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr_block" {
  description = "서브넷에 할당할 CIDR 블록"
  type        = string
  default     = "10.0.1.0/24"
}

variable "availability_zone" {
  description = "서브넷을 배치할 가용영역"
  type        = string
  default     = "us-east-1a"
}

variable "instance_type" {
  description = "EC2 인스턴스 유형"
  type        = string
  default     = "t2.micro"
}

variable "associate_public_ip" {
  description = "EC2 인스턴스에 퍼블릭 IP 할당 여부"
  type        = bool
  default     = true
}

