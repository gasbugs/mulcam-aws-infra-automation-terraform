# Terraform 및 AWS 프로바이더 버전 설정
terraform {
  required_version = ">= 1.13.4" # Terraform 최소 요구 버전
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 프로바이더의 소스 지정
      version = ">= 6.19.0"     # 5.73 버전 이상의 AWS 프로바이더 사용
    }
  }
}

# AWS 프로바이더 설정
provider "aws" {
  region  = var.aws_region  # 리소스를 배포할 AWS 리전
  profile = var.aws_profile # 인증에 사용할 AWS CLI 프로파일
}

# 랜덤한 숫자 생성 (bucket 이름에 사용)
resource "random_integer" "bucket_suffix" {
  min = 1000 # 최소 값
  max = 9999 # 최대 값
}

# S3 버킷 생성
resource "aws_s3_bucket" "static_site" {
  bucket = "${var.bucket_name}-${random_integer.bucket_suffix.result}" # 버킷 이름에 랜덤 숫자 추가

  tags = {
    Name        = var.bucket_name # 태그로 버킷 이름 설정
    Environment = var.environment # 환경에 대한 태그 지정 (예: dev, prod)
  }
}

# S3 버킷의 정적 웹사이트 설정 구성
resource "aws_s3_bucket_website_configuration" "static_site_website" {
  bucket = aws_s3_bucket.static_site.id # 대상 버킷 지정


  index_document {
    suffix = var.index_document # 인덱스 문서 설정 (예: index.html)
  }

  error_document {
    key = var.error_document # 에러 문서 설정 (예: error.html)
  }
}

# S3 버킷에 대한 정책 설정
resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = aws_s3_bucket.static_site.id # 정책이 적용될 버킷 지정

  # depends_on을 통해 S3 버킷과 Public Access Block 설정이 완료된 후에 정책을 적용
  depends_on = [
    aws_s3_bucket.static_site,
    aws_s3_bucket_public_access_block.static_site_public_access_block
  ]


  policy = jsonencode({
    Version = "2012-10-17" # 정책 버전
    Statement = [
      {
        Effect    = "Allow"                              # 허용 정책
        Principal = "*"                                  # 모든 사용자에게 적용
        Action    = "s3:GetObject"                       # S3 오브젝트 읽기 허용
        Resource  = "${aws_s3_bucket.static_site.arn}/*" # 버킷 내 모든 오브젝트에 대한 접근 권한
      }
    ]
  })
}

# S3 버킷의 Public Access Block 설정 해제
resource "aws_s3_bucket_public_access_block" "static_site_public_access_block" {
  bucket = aws_s3_bucket.static_site.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# S3 버킷에 인덱스 파일 업로드
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.static_site.id # 대상 버킷 지정
  key          = var.index_document           # 업로드할 오브젝트의 키 (파일명)
  source       = var.index_document_path      # 로컬에서 업로드할 인덱스 파일의 경로
  content_type = "text/html"                  # 파일의 MIME 타입 설정
}

# S3 버킷에 에러 파일 업로드
resource "aws_s3_object" "error" {
  bucket       = aws_s3_bucket.static_site.id # 대상 버킷 지정
  key          = var.error_document           # 업로드할 오브젝트의 키 (파일명)
  source       = var.error_document_path      # 로컬에서 업로드할 에러 파일의 경로
  content_type = "text/html"                  # 파일의 MIME 타입 설정
}
