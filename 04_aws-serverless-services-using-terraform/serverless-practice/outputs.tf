# 생성된 S3 버킷의 이름 출력 (공식 모듈 출력값: s3_bucket_id)
output "bucket_name" {
  description = "The name of the S3 bucket."
  value       = module.s3.s3_bucket_id
}

# 생성된 S3 버킷의 도메인 이름 출력 (공식 모듈 출력값: s3_bucket_bucket_regional_domain_name)
output "bucket_domain_name" {
  description = "The domain name of the S3 bucket."
  value       = module.s3.s3_bucket_bucket_regional_domain_name
}

# 생성된 CloudFront URL
output "cloudfront_url" {
  description = "The URL of the CloudFront distribution."
  value       = module.cloudfront.cloudfront_domain_name
}

# EC2 인스턴스의 퍼블릭 IP 출력
output "ec2_public_ip" {
  description = "The public IP address of the EC2 instance."
  value       = module.route53_with_ec2.ec2_public_ip
}

# SSH 접속용 프라이빗 키 경로 출력
output "private_key_path" {
  description = "Path to the locally saved private key file for SSH access."
  value       = module.route53_with_ec2.private_key_path
}

# Private Hosted Zone ID 출력
output "private_dns_zone_id" {
  description = "The ID of the created private DNS hosted zone."
  value       = module.route53_with_ec2.private_dns_zone_id
}
