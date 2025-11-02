variable "aws_region" {
  description = "Region for AWS"
  type        = string
  default     = "us-east-1"
}

variable "docker_hub_username" {
  type = string
}

variable "docker_hub_password" {
  type = string
}

variable "key_path" {
  default = "C:/users/isc03/.ssh/my-key.pub"
}
