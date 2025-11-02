variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
}

variable "aws_profile" {
  description = "AWS profile for all resources"
  type        = string
}

# VPC Variables
variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets"
  type        = list(string)
}

variable "availability_zones" {
  description = "List of availability zones for the subnets"
  type        = list(string)
}

variable "project_name" {
  description = "Project name for tagging resources"
  type        = string
}

/*
variable "elastic_ips" {
  description = "List of EIP allocation IDs for NAT Gateways"
  type        = list(string)
}
*/

# DynamoDB Variables
variable "dynamodb_table_name" {
  description = "Name of the DynamoDB table"
  type        = string
}

variable "dynamodb_hash_key" {
  description = "Hash key attribute name for the DynamoDB table"
  type        = string
}

variable "dynamodb_hash_key_type" {
  description = "Data type for the hash key (e.g., S, N)"
  type        = string
  default     = "S"
}

variable "dynamodb_range_key" {
  description = "Range key attribute name for the DynamoDB table"
  type        = string
  default     = null
}

variable "dynamodb_range_key_type" {
  description = "Data type for the range key (e.g., S, N)"
  type        = string
  default     = "S"
}

variable "dynamodb_billing_mode" {
  description = "Billing mode for the DynamoDB table"
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "dynamodb_read_capacity" {
  description = "Read capacity for provisioned mode"
  type        = number
  default     = 5
}

variable "dynamodb_write_capacity" {
  description = "Write capacity for provisioned mode"
  type        = number
  default     = 5
}

# Redis Variables
variable "redis_allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access Redis"
  type        = list(string)
}

variable "redis_node_type" {
  description = "Instance type for Redis"
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_num_cache_nodes" {
  description = "Number of cache nodes for Redis"
  type        = number
  default     = 1
}

variable "redis_parameter_group_name" {
  description = "Parameter group for Redis"
  type        = string
  default     = "default.redis7"
}

# EC2 Variables
variable "ec2_ami_id" {
  description = "AMI ID for the EC2 instance"
  type        = string
}

variable "ec2_instance_type" {
  description = "Instance type for EC2"
  type        = string
  default     = "t2.micro"
}

variable "ec2_public_key_path" {
  description = "Key path of ssh ec2 public key"
  type        = string
}

variable "ec2_allowed_ssh_cidr_blocks" {
  description = "CIDR blocks allowed for SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ec2_user_data" {
  description = "User data script for EC2 instance"
  type        = string
  default     = ""
}

variable "redis_auth_token" {
  description = "redis의 인증 토큰"
  type        = string
}

# RDS mysql 변수
variable "rds_mysql_allowed_cidr" {
  default = "10.0.0.0/16"
}

variable "rds_mysql_db_allocated_storage" {
  default = 20
}

variable "rds_mysql_db_engine_version" {
  default = "8.0.mysql_aurora.3.10.1"
}

variable "rds_mysql_db_instance_class" {
  default = "db.t3.micro"
}

variable "rds_mysql_db_name" {
  default = "mydatabase"
}

variable "rds_mysql_db_username" {
  default = "admin"
}

variable "rds_mysql_db_password" {
  description = "민감 정보, 환경 변수로도 관리 가능"
  default     = "securepassword123!"
}

variable "rds_mysql_db_parameter_group_name" {
  description = "DB Parameter Group"
  default     = "default.mysql8.0"
}

variable "rds_mysql_db_multi_az" {
  description = "RDS 멀티 AZ 설정"
  default     = true
}
