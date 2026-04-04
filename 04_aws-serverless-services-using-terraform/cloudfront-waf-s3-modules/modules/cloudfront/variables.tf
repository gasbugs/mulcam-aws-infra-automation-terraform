# CloudFront + WAF 모듈이 외부(root 모듈)에서 받아야 할 입력값을 정의합니다.

# WAF/OAC/CloudFront 리소스 이름에 사용할 S3 버킷 기본 이름
variable "bucket_name" {
  description = "S3 버킷의 기본 이름"
  type        = string
}

# 버킷 정책에서 정책을 적용할 버킷을 지정할 때 사용하는 버킷 ID(이름)
variable "bucket_id" {
  description = "S3 버킷의 ID"
  type        = string
}

# CloudFront 오리진 도메인 — OAC 방식에는 반드시 지역(regional) 엔드포인트를 사용해야 합니다.
variable "bucket_domain_name" {
  description = "S3 버킷의 지역 도메인 이름 (OAC 연동용)"
  type        = string
}

# 버킷 정책에서 "이 버킷의 파일만 접근 허용" 조건을 지정할 때 사용하는 버킷 ARN
# ARN(Amazon Resource Name): AWS 리소스를 전 세계에서 유일하게 식별하는 이름 형식
variable "bucket_arn" {
  description = "S3 버킷의 ARN"
  type        = string
}

# CloudFront 도메인 루트(/)에 접속했을 때 기본으로 보여줄 파일 이름
variable "index_document" {
  description = "CloudFront 기본 루트 오브젝트 (예: index.html)"
  type        = string
}

# 존재하지 않는 페이지에 접속했을 때(403 오류) 보여줄 에러 페이지 파일 이름
variable "error_document" {
  description = "오류 발생 시 보여줄 에러 페이지 파일 이름 (예: error.html)"
  type        = string
}
