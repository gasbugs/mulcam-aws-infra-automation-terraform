# AWS 리전을 지정하는 변수
variable "aws_region" {
  description = "리소스를 생성할 AWS 리전" # 변수에 대한 설명
  type        = string            # 변수 타입
  default     = "us-east-1"       # 기본값 (미국 동부 리전)
}

# 사용할 AWS CLI 프로파일을 지정하는 변수
variable "aws_profile" {
  description = "사용할 AWS CLI 프로파일" # 변수에 대한 설명
  type        = string             # 변수 타입
  default     = "my-profile"       # 기본값 (사용자 정의 프로파일)
}

# 생성할 S3 버킷의 이름을 지정하는 변수
variable "bucket_name" {
  description = "S3 버킷의 이름" # 변수에 대한 설명
  type        = string      # 변수 타입
}

# 인덱스 문서의 이름을 지정하는 변수 (예: index.html)
variable "index_document" {
  description = "인덱스 문서의 이름 (예: index.html)" # 변수에 대한 설명
  type        = string                       # 변수 타입
  default     = "index.html"                 # 기본값
}

# 에러 문서의 이름을 지정하는 변수 (예: error.html)
variable "error_document" {
  description = "에러 문서의 이름 (예: error.html)" # 변수에 대한 설명
  type        = string                      # 변수 타입
  default     = "error.html"                # 기본값
}

# 로컬에서 업로드할 인덱스 문서 파일의 경로를 지정하는 변수
variable "index_document_path" {
  description = "로컬 인덱스 문서 파일의 경로" # 변수에 대한 설명
  type        = string             # 변수 타입
}

# 로컬에서 업로드할 에러 문서 파일의 경로를 지정하는 변수
variable "error_document_path" {
  description = "로컬 에러 문서 파일의 경로" # 변수에 대한 설명
  type        = string            # 변수 타입
}

# S3 버킷에 적용할 환경 태그를 지정하는 변수 (예: dev, prod)
variable "environment" {
  description = "버킷의 환경 태그 (예: dev, prod)" # 변수에 대한 설명
  type        = string                     # 변수 타입
  default     = "dev"                      # 기본값
}
