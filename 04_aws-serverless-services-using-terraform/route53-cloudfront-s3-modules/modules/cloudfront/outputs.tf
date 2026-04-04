output "cloudfront_domain_name" {
  description = "CloudFront 배포 도메인 이름"
  value       = aws_cloudfront_distribution.s3_distribution.domain_name
}

output "cloudfront_hosted_zone_id" {
  description = "Route53 alias 레코드 설정에 사용할 CloudFront hosted zone ID"
  value       = aws_cloudfront_distribution.s3_distribution.hosted_zone_id
}

output "cloudfront_distribution_arn" {
  description = "S3 버킷 정책 조건에 사용할 CloudFront 배포 ARN"
  value       = aws_cloudfront_distribution.s3_distribution.arn
}
