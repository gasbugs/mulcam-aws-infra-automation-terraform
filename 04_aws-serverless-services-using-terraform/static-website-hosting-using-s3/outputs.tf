# outputs.tf

# 생성된 S3 버킷의 이름 출력
output "bucket_name" {
  description = "The name of the S3 bucket."     # 출력 변수에 대한 설명
  value       = aws_s3_bucket.static_site.bucket # 생성된 S3 버킷의 이름을 출력
}

# 생성된 S3 버킷의 웹사이트 URL 출력
output "website_url" {
  description = "The website URL for the S3 bucket."                                     # 출력 변수에 대한 설명
  value       = aws_s3_bucket_website_configuration.static_site_website.website_endpoint # S3 버킷 웹사이트의 엔드포인트 URL 출력
}
