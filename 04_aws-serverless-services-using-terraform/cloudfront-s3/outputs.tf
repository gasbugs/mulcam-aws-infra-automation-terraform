# outputs.tf
# Terraform 적용(apply) 완료 후 터미널에 출력할 결과값을 정의합니다.
# 생성된 리소스의 주소나 이름 등 확인이 필요한 정보를 여기에 작성합니다.

# 생성된 S3 버킷의 실제 이름을 출력합니다.
# 버킷 이름에 랜덤 숫자가 붙으므로, apply 후 이 출력으로 정확한 이름을 확인할 수 있습니다.
output "bucket_name" {
  description = "생성된 S3 버킷의 실제 이름 (랜덤 숫자가 포함된 전체 이름)"
  value       = aws_s3_bucket.static_site.bucket
}

# 웹사이트에 접속할 수 있는 CloudFront URL을 출력합니다.
# apply 완료 후 이 주소를 브라우저에 입력하면 배포한 웹사이트를 확인할 수 있습니다.
output "cloudfront_url" {
  description = "웹사이트 접속 주소 (브라우저에서 https://[이 값] 으로 접속하세요)"
  value       = "https://${aws_cloudfront_distribution.s3_distribution.domain_name}"
}
