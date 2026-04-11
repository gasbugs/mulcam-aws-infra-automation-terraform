# 출력값 정의 — apply 완료 후 역할 위임 테스트에 필요한 정보

output "user_name" {
  description = "생성된 IAM 사용자의 이름"
  value       = aws_iam_user.example_user.name
}

output "s3_read_role_arn" {
  description = "S3 읽기 권한이 부여된 IAM 역할의 ARN(고유 리소스 식별자)"
  value       = aws_iam_role.s3_read_role.arn
}

# Access Key ID 출력
output "user_access_key_id" {
  description = "IAM 사용자의 액세스 키 ID — CLI 설정 시 사용"
  value       = aws_iam_access_key.example_user_key.id
}

# Secret Access Key 출력
output "user_secret_access_key" {
  description = "IAM 사용자의 시크릿 액세스 키 — CLI 설정 시 사용 (민감 정보)"
  value       = aws_iam_access_key.example_user_key.secret
  sensitive   = true # 이 옵션을 통해 출력 시 민감한 정보로 표시
}
