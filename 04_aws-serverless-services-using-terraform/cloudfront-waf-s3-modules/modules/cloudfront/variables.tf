variable "bucket_name" {
  description = "S3 버킷의 기본 이름"
  type        = string
}

variable "bucket_id" {
  description = "S3 버킷의 ID"
  type        = string
}

variable "bucket_domain_name" {
  description = "S3 버킷의 도메인 이름"
  type        = string
}

variable "bucket_arn" {
  description = "S3 버킷의 ARN"
  type        = string
}

variable "index_document" {
  description = "CloudFront 기본 루트 오브젝트 (예: index.html)"
  type        = string
}
