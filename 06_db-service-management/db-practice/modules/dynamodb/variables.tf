variable "vpc_id" {
  description = "VPC ID to create the DynamoDB VPC endpoint"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs where the DynamoDB endpoint will be accessible"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets"
  type        = list(string)
}

variable "region" {
  description = "AWS region for DynamoDB and VPC endpoint"
  type        = string
}

variable "project_name" {
  description = "Project name for tagging resources"
  type        = string
}

# DynamoDB Table Variables
variable "table_name" {
  description = "Name of the DynamoDB table"
  type        = string
}

variable "hash_key" {
  description = "Hash key attribute name for the DynamoDB table"
  type        = string
}

variable "hash_key_type" {
  description = "Data type for the hash key (e.g., S, N)"
  type        = string
  default     = "S"
}

variable "range_key" {
  description = "Range key attribute name for the DynamoDB table"
  type        = string
  default     = null
}

variable "range_key_type" {
  description = "Data type for the range key (e.g., S, N)"
  type        = string
  default     = "S"
}

variable "billing_mode" {
  description = "Billing mode for the table (PROVISIONED or PAY_PER_REQUEST)"
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "read_capacity" {
  description = "Read capacity for provisioned mode"
  type        = number
  default     = 5
}

variable "write_capacity" {
  description = "Write capacity for provisioned mode"
  type        = number
  default     = 5
}
