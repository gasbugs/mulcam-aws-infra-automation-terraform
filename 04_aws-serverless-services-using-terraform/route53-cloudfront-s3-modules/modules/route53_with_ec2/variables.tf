variable "aws_region" {
  default = "us-east-1"
}

variable "private_dns_name" {
  description = "Private DNS 도메인 이름"
  type        = string
}

variable "ami_id" {
  description = "EC2 인스턴스에 사용할 AMI ID"
  type        = string
}

variable "instance_type" {
  description = "EC2 인스턴스 타입"
  type        = string
}

variable "pub_key_file_path" {
  description = "공개 키 위치 정보"
  type        = string
}

variable "cloudfront_domain_name" {
  description = "aws_cloudfront_distribution.s3_distribution.domain_name"
  type        = string
}

variable "cloudfront_hosted_zone_id" {
  description = "aws_cloudfront_distribution.s3_distribution.hosted_zone_id"
  type        = string
}
