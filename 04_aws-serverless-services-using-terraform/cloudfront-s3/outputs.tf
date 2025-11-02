# outputs.tf

# 생성된 S3 버킷의 이름 출력
output "bucket_name" {
  description = "The name of the S3 bucket."     # 출력 변수에 대한 설명
  value       = aws_s3_bucket.static_site.bucket # 생성된 S3 버킷의 이름을 출력
}

# 클라우드프론트 URL
output "cloudfront_url" {
  description = "클라우드프론트 URL"
  value       = aws_cloudfront_distribution.s3_distribution.domain_name
}
