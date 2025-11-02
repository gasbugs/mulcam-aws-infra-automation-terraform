variable "aws_region" {
  default = "us-east-1"
}

variable "db_username" {
  description = "Database administrator username"
  type        = string
  #sensitive   = true
}

variable "db_password" {
  description = "Database administrator password"
  type        = string
  #sensitive   = true
}
