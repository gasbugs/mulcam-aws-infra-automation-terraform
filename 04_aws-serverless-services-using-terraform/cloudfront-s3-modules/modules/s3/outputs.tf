# S3 버킷 정책에 대한 출력
output "bucket_id" {
  value = aws_s3_bucket.static_site.id
}

output "bucket_domain_name" {
  value = aws_s3_bucket.static_site.bucket_domain_name
}

output "bucket_arn" {
  value = aws_s3_bucket.static_site.arn
}
