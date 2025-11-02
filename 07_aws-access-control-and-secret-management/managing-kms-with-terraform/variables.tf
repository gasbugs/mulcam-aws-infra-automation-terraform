variable "aws_region" {
  description = "The AWS region to create resources in"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "The AWS region to create resources in"
  type        = string
  default     = "my=sso"
}

variable "bucket_name" {
  description = "The name of the S3 bucket"
  type        = string
  default     = "my-example-secure-bucket"
}

variable "ami_id" {
  description = "The AMI ID for EC2 instance"
  type        = string
  default     = "ami-0c94855ba95c71c99" # Example AMI ID for Amazon Linux 2 in us-west-2 region
}

variable "key_path" {
  description = "The path of the SSH Pub key for EC2"
  type        = string
}
