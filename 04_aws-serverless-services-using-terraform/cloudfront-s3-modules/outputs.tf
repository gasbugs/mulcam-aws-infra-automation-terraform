# 생성된 S3 버킷의 이름 출력
output "bucket_name" {
  description = "The name of the S3 bucket."
  value       = module.s3.bucket_id # S3 모듈에서 출력된 버킷 ID 사용
}

# 생성된 S3 버킷의 도메인 이름 출력
output "bucket_domain_name" {
  description = "The domain name of the S3 bucket."
  value       = module.s3.bucket_domain_name # S3 모듈에서 출력된 버킷 도메인 이름 사용
}

# 생성된 CloudFront URL
output "cloudfront_url" {
  description = "The URL of the CloudFront distribution."
  value       = module.cloudfront.cloudfront_domain_name # CloudFront 모듈에서 출력된 도메인 이름 사용
}
