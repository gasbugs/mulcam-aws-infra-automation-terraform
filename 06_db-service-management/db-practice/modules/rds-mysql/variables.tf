#######################################
# RDS에 대한 변수

variable "allowed_cidr" {
  description = "The CIDR block allowed to access the RDS instance"
  type        = string
}

variable "db_allocated_storage" {
  description = "The allocated storage size for the RDS instance in GB"
  type        = number
  default     = 20
}

variable "db_engine_version" {
  description = "The version of the database engine"
  type        = string
  default     = "8.0.mysql_aurora.3.10.1"
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
  description = "The name of the DB parameter group"
  type        = string
  default     = "default.mysql8.0"
}

variable "db_multi_az" {
  description = "Whether the RDS instance is multi-AZ"
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "VPC ID to create the DynamoDB VPC endpoint"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs where the DynamoDB endpoint will be accessible"
  type        = list(string)
}
