# 프라이더 정보 
variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
}

variable "aws_profile" {
  description = "AWS profile for all resources"
  type        = string
}

# 유저 정보 
variable "user_name" {
  description = "The name of the IAM user"
  type        = string
  default     = "example_user"
}

variable "s3_policy_file" {
  description = "The path to the JSON file containing the S3 read-only policy"
  type        = string
  default     = "s3-readonly-policy.json"
}
