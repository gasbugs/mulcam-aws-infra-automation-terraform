output "bucket_id" {
  description = "S3 버킷 ID (버킷 이름)"
  value       = aws_s3_bucket.static_site.id
}

output "bucket_domain_name" {
  description = "CloudFront OAC 연동용 S3 지역 엔드포인트"
  value       = aws_s3_bucket.static_site.bucket_regional_domain_name
}

output "bucket_arn" {
  description = "S3 버킷 ARN"
  value       = aws_s3_bucket.static_site.arn
}
