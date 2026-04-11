variable "allowed_ssh_cidr_blocks" {
  description = "CIDR blocks allowed to SSH to the practice EC2 instance"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "aws_region" {
  description = "AWS region for the practice resources"
  type        = string
  default     = "us-east-1"
}

variable "docker_hub_access_token" {
  description = "Docker Hub personal access token for authenticated pull-through cache access"
  type        = string
  default     = null
  sensitive   = true
  nullable    = true
}

variable "docker_hub_username" {
  description = "Docker Hub username for authenticated pull-through cache access"
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = (
      (var.docker_hub_username == null && var.docker_hub_access_token == null) ||
      (var.docker_hub_username != null && var.docker_hub_access_token != null)
    )
    error_message = "docker_hub_username and docker_hub_access_token must be set together."
  }
}

variable "instance_type" {
  description = "EC2 instance type used to test image pulls"
  type        = string
  default     = "t3.micro"
}

variable "project_name" {
  description = "Project name used for tagging and resource naming"
  type        = string
  default     = "ecr-cache-lab"
}

variable "pull_through_cache_prefix" {
  description = "Prefix used by Amazon ECR pull-through cache"
  type        = string
  default     = "docker-hub"
}

variable "repository_name" {
  description = "Name of the practice ECR private repository"
  type        = string
  default     = "my-ecr-repo"
}
