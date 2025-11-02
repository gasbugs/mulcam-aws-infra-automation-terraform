# 생성된 IAM 유저의 이름 출력
output "ec2_user_name" {
  description = "Name of the created IAM user"
  value       = aws_iam_user.ec2_user.name
}

# 생성된 IAM 그룹의 이름 출력
output "ec2_group_name" {
  description = "Name of the created IAM group"
  value       = aws_iam_group.ec2_managers.name
}

# Access Key ID 출력
output "ec2_user_access_key_id" {
  description = "Access Key ID for the IAM user"
  value       = aws_iam_access_key.ec2_user_key.id
}

# Secret Access Key 출력
output "ec2_user_secret_access_key" {
  description = "Secret Access Key for the IAM user"
  value       = aws_iam_access_key.ec2_user_key.secret
  sensitive   = true # 이 옵션을 통해 출력 시 민감한 정보로 표시
}
