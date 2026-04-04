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

# CloudFront OAC 방식 사용 시 퍼블릭 액세스 차단 필수
resource "aws_s3_bucket_public_access_block" "static_site" {
  bucket                  = aws_s3_bucket.static_site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 버킷에 인덱스 파일 업로드
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.static_site.id
  key          = var.index_document
  source       = var.index_document_path
  content_type = "text/html"
  etag         = filemd5(var.index_document_path)
}

# S3 버킷에 에러 파일 업로드
resource "aws_s3_object" "error" {
  bucket       = aws_s3_bucket.static_site.id
  key          = var.error_document
  source       = var.error_document_path
  content_type = "text/html"
  etag         = filemd5(var.error_document_path)
}

