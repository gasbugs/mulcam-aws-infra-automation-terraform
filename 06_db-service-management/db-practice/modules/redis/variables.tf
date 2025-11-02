variable "vpc_id" {
  description = "ID of the VPC where Redis will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs where Redis will be deployed"
  type        = list(string)
}

variable "project_name" {
  description = "Project name for tagging resources"
  type        = string
}

variable "allowed_cidr_blocks" {
  description = "List of CIDR blocks allowed to access Redis"
  type        = list(string)
}

variable "node_type" {
  description = "Instance type for the Redis nodes"
  type        = string
  default     = "cache.t3.micro"
}

variable "num_cache_nodes" {
  description = "Number of cache nodes for Redis"
  type        = number
  default     = 1
}

variable "parameter_group_name" {
  description = "Parameter group for Redis configuration"
  type        = string
  default     = "default.redis7"
}

variable "redis_auth_token" {
  description = "redis의 인증 토큰"
  type        = string
}

