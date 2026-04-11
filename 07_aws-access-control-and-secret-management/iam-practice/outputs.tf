# 출력값 정의 — apply 완료 후 IAM 실습에 필요한 정보

output "user_name" {
  description = "생성된 IAM 프로젝트 멤버 사용자 이름"
  value       = aws_iam_user.project_member.name
}

output "s3_project_data_rw_arn" {
  description = "S3 읽기/쓰기 정책의 ARN (Amazon 리소스 고유 식별자)"
  value       = aws_iam_policy.s3_rw_policy.arn
}

# Access Key ID 출력
output "user_access_key_id" {
  description = "IAM 사용자의 프로그래밍 방식 접근 키 ID"
  value       = aws_iam_access_key.example_user_key.id
}

# Secret Access Key 출력
output "user_secret_access_key" {
  description = "IAM 사용자의 시크릿 액세스 키 — 외부에 노출되지 않도록 민감 정보로 표시"
  value       = aws_iam_access_key.example_user_key.secret
  sensitive   = true # 이 옵션을 통해 출력 시 민감한 정보로 표시
}
