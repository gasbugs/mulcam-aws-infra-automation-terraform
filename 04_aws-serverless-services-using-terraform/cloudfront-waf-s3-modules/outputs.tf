# 이 파일은 terraform apply 완료 후 터미널에 출력될 결과값을 정의합니다.
# 만들어진 리소스의 이름이나 주소를 확인할 때 사용합니다.

# 실제로 생성된 S3 버킷의 이름입니다 (랜덤 숫자가 붙어 있습니다).
output "bucket_name" {
  description = "생성된 S3 버킷의 이름"
  value       = module.s3.bucket_id
}

# S3 버킷에 직접 접근할 수 있는 AWS 도메인 주소입니다.
# 실제 서비스는 CloudFront URL을 통해 접근해야 합니다 (S3 직접 접근은 차단됨).
output "bucket_domain_name" {
  description = "생성된 S3 버킷의 도메인 이름"
  value       = module.s3.bucket_domain_name
}

# 웹사이트 방문자가 실제로 사용할 CloudFront 주소입니다.
# 이 주소를 브라우저에 입력하면 웹사이트에 접속할 수 있습니다.
output "cloudfront_url" {
  description = "배포된 CloudFront의 접속 URL"
  value       = "https://${module.cloudfront.cloudfront_domain_name}"
}
