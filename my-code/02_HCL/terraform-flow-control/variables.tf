variable "environment" {
  description = "The deployment environment (e.g. dev, prod)"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "The AWS region to deploy to"
  type        = string
  default     = "us-east-1"
}

variable "enable_monitoring" {
  description = "Whether to enable detailed monitoring for the EC2 instance"
  type        = bool
  default     = false
}

variable "custom_user_data" {
  description = "Custom user data for the EC2 instance"
  type        = string
  default     = ""
}

variable "create_bucket" {
  description = "Whether to create the S3 bucket"
  type        = bool
  default     = false
}
