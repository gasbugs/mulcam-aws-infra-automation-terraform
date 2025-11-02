# 랜덤한 숫자 생성 (bucket 이름에 사용)
resource "random_integer" "bucket_suffix" {
  min = 1000
  max = 9999
}

# S3 버킷 생성
resource "aws_s3_bucket" "static_site" {
  bucket = "${var.bucket_name}-${random_integer.bucket_suffix.result}"

  tags = {
    Name        = var.bucket_name
    Environment = var.environment
  }
}

# S3 버킷의 정적 웹사이트 설정 구성
resource "aws_s3_bucket_website_configuration" "static_site_website" {
  bucket = aws_s3_bucket.static_site.id

  index_document {
    suffix = var.index_document
  }

  error_document {
    key = var.error_document
  }
}

# S3 버킷에 인덱스 파일 업로드
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.static_site.id
  key          = var.index_document
  source       = var.index_document_path
  content_type = "text/html"
}

# S3 버킷에 에러 파일 업로드
resource "aws_s3_object" "error" {
  bucket       = aws_s3_bucket.static_site.id
  key          = var.error_document
  source       = var.error_document_path
  content_type = "text/html"
}

