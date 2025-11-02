variable "vpc_id" {
  description = "ID of the VPC where EC2 will be deployed"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for the EC2 instance"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for the EC2 instance"
  type        = string
}

variable "instance_type" {
  description = "Instance type for the EC2"
  type        = string
  default     = "t2.micro"
}

variable "public_key_path" {
  description = "Key path of ssh ec2 public key"
  type        = string
}

variable "project_name" {
  description = "Project name for tagging resources"
  type        = string
}

variable "allowed_ssh_cidr_blocks" {
  description = "List of CIDR blocks allowed for SSH access to EC2"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "redis_cidr_blocks" {
  description = "List of CIDR blocks allowed to access Redis from EC2"
  type        = list(string)
}

variable "user_data" {
  description = "User data script to launch EC2"
  type        = string
  default     = "sudo yum install python3-pip && sudo pip3 install redis"
}

variable "ec2_instance_profile" {
  description = "ec2에 부여할 dynamodb 접근 프로파일"
  type        = string
}
