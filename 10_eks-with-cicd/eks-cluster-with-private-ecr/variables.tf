variable "aws_region" {
  description = "Region for AWS"
  type        = string
}

variable "key_path" {
  description = "퍼블릭 키 경로 구성"
  type        = string
  default     = "C:/users/isc03/.ssh/my-key.pub"
}
