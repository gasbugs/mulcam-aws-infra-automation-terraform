# 이 파일은 CloudFront 모듈 안에서 만들어진 값을 외부(root 모듈)로 내보냅니다.

# 방문자가 웹사이트에 접속할 때 사용하는 CloudFront 도메인 주소입니다.
# 예: d1234abcd.cloudfront.net
# root 모듈의 outputs.tf에서 이 값을 가져다 최종 출력합니다.
output "cloudfront_domain_name" {
  description = "CloudFront 배포 도메인 이름"
  value       = aws_cloudfront_distribution.s3_distribution.domain_name
}
