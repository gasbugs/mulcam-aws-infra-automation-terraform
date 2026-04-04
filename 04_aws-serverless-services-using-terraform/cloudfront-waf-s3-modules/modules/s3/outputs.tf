# 이 파일은 S3 모듈 안에서 만들어진 값을 외부(root 모듈)로 내보냅니다.
# CloudFront 모듈이 S3 정보를 참조할 때 이 출력값을 사용합니다.

# 버킷의 고유 이름 — CloudFront 버킷 정책에서 어느 버킷에 정책을 적용할지 지정할 때 사용합니다.
output "bucket_id" {
  description = "S3 버킷 ID (버킷 이름)"
  value       = aws_s3_bucket.static_site.id
}

# CloudFront OAC 방식에서는 반드시 지역(regional) 엔드포인트를 사용해야 합니다.
# 일반 도메인(bucket_domain_name)은 글로벌 엔드포인트라 OAC 서명 검증이 실패할 수 있습니다.
output "bucket_domain_name" {
  description = "CloudFront OAC 연동용 S3 지역 엔드포인트"
  value       = aws_s3_bucket.static_site.bucket_regional_domain_name
}

# 버킷의 전체 고유 식별자(ARN) — 버킷 정책에서 "이 버킷의 파일만 허용"할 때 사용합니다.
# ARN(Amazon Resource Name): AWS 리소스를 전 세계에서 유일하게 식별하는 이름 형식
output "bucket_arn" {
  description = "S3 버킷 ARN"
  value       = aws_s3_bucket.static_site.arn
}
