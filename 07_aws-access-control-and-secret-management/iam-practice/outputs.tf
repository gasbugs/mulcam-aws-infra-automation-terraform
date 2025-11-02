output "user_name" {
  description = "The name of the IAM user"
  value       = aws_iam_user.project_member.name
}

output "s3_project_data_rw_arn" {
  description = "ARN of the role that allows S3 read write access"
  value       = aws_iam_policy.s3_rw_policy.arn
}

# Access Key ID 출력
output "user_access_key_id" {
  description = "Access Key ID for the IAM user"
  value       = aws_iam_access_key.example_user_key.id
}

# Secret Access Key 출력
output "user_secret_access_key" {
  description = "Secret Access Key for the IAM user"
  value       = aws_iam_access_key.example_user_key.secret
  sensitive   = true # 이 옵션을 통해 출력 시 민감한 정보로 표시
}
