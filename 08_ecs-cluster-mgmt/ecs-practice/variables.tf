variable "aws_region" {
  description = "AWS region for the ECS on EC2 practice"
  type        = string
  default     = "us-east-1"
}

variable "container_image" {
  description = "Container image deployed to the ECS service"
  type        = string
  default     = "public.ecr.aws/nginx/nginx:stable-alpine"
}

variable "container_name" {
  description = "Name of the application container in the ECS task definition"
  type        = string
  default     = "nginx-container"
}

variable "container_port" {
  description = "Port exposed by the container"
  type        = number
  default     = 80
}

variable "desired_count" {
  description = "Number of ECS tasks to keep running"
  type        = number
  default     = 1
}

variable "ec2_instance_type" {
  description = "EC2 instance type used by the ECS container instances"
  type        = string
  default     = "t3.micro"
}

variable "health_check_path" {
  description = "HTTP path used by the ALB target group health check"
  type        = string
  default     = "/"
}

variable "project_name" {
  description = "Project name used for naming and tagging resources"
  type        = string
  default     = "ecs-practice"
}

variable "task_cpu" {
  description = "CPU units for the ECS task definition"
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "Memory in MiB for the ECS task definition"
  type        = string
  default     = "512"
}

variable "vpc_cidr" {
  description = "CIDR block used for the ECS practice VPC"
  type        = string
  default     = "10.0.0.0/16"
}
