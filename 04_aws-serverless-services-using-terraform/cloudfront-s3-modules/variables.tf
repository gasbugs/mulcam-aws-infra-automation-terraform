variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI 프로파일"
  type        = string
  default     = "my-profile"
}

variable "bucket_name" {
  description = "S3 버킷의 기본 이름"
  type        = string
  default     = "my-static-site"
}

variable "environment" {
  description = "환경 설정 (dev 또는 prod)"
  type        = string
  default     = "dev"
}

variable "index_document" {
  description = "정적 웹사이트 인덱스 문서"
  type        = string
  default     = "index.html"
}

variable "error_document" {
  description = "정적 웹사이트 에러 문서"
  type        = string
  default     = "error.html"
}

variable "index_document_path" {
  description = "로컬의 인덱스 문서 경로"
  type        = string
  default     = "web/index.html"
}

variable "error_document_path" {
  description = "로컬의 에러 문서 경로"
  type        = string
  default     = "web/error.html"
}
