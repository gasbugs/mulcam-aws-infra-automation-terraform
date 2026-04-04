output "cloudfront_domain_name" {
  description = "CloudFront 배포 도메인 이름"
  value       = aws_cloudfront_distribution.s3_distribution.domain_name
}

output "cloudfront_distribution_arn" {
  description = "S3 버킷 정책 조건에 사용할 CloudFront 배포 ARN"
  value       = aws_cloudfront_distribution.s3_distribution.arn
}
