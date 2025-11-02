variable "bucket_name" {
  description = "S3 버킷의 기본 이름"
  type        = string
}

variable "environment" {
  description = "환경 설정 (dev 또는 prod)"
  type        = string
}

variable "index_document" {
  description = "정적 웹사이트 인덱스 문서"
  type        = string
}

variable "error_document" {
  description = "정적 웹사이트 에러 문서"
  type        = string
}

variable "index_document_path" {
  description = "로컬의 인덱스 문서 경로"
  type        = string
}

variable "error_document_path" {
  description = "로컬의 에러 문서 경로"
  type        = string
}
