# 이 파일은 Terraform이 사용할 입력값(변수)을 정의합니다.
# default 값이 설정되어 있으면 별도로 값을 지정하지 않아도 자동으로 사용됩니다.

# 리소스를 어느 AWS 지역(데이터 센터)에 만들지 설정합니다.
variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "us-east-1" # 미국 동부(버지니아) 리전 — WAF는 CloudFront와 함께 us-east-1에서만 생성 가능
}

# AWS 계정 접속에 사용할 프로파일 이름입니다 (~/.aws/config 파일에 설정된 이름).
variable "aws_profile" {
  description = "AWS CLI 프로파일"
  type        = string
  default     = "my-profile"
}

# S3 버킷의 기본 이름입니다. 실제 버킷 이름에는 랜덤 숫자가 추가되어 전 세계에서 유일한 이름이 만들어집니다.
variable "bucket_name" {
  description = "S3 버킷의 기본 이름"
  type        = string
  default     = "my-static-site"
}

# 운영 환경을 구분하는 값입니다. 리소스 이름이나 태그에 사용됩니다.
variable "environment" {
  description = "환경 설정 (dev 또는 prod)"
  type        = string
  default     = "dev"
}

# 웹사이트에 접속했을 때 처음으로 보여줄 파일 이름입니다.
variable "index_document" {
  description = "정적 웹사이트 인덱스 문서"
  type        = string
  default     = "index.html"
}

# 존재하지 않는 페이지에 접속했을 때 보여줄 에러 페이지 파일 이름입니다.
variable "error_document" {
  description = "정적 웹사이트 에러 문서"
  type        = string
  default     = "error.html"
}

# S3에 업로드할 인덱스 파일이 내 컴퓨터의 어디에 있는지 경로입니다.
variable "index_document_path" {
  description = "로컬의 인덱스 문서 경로"
  type        = string
  default     = "web/index.html"
}

# S3에 업로드할 에러 페이지 파일이 내 컴퓨터의 어디에 있는지 경로입니다.
variable "error_document_path" {
  description = "로컬의 에러 문서 경로"
  type        = string
  default     = "web/error.html"
}
