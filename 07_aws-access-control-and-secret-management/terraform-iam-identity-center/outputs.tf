# outputs.tf

# 그룹 ID 출력
output "group_id" {
  description = "The ID of the group created in AWS Identity Store."
  value       = aws_identitystore_group.sso_group.group_id
}

# 유저 ID 출력
output "user_id" {
  description = "The ID of the user created in AWS Identity Store."
  value       = aws_identitystore_user.sso_user.user_id
}

# 유저의 로그인 이름 출력
output "user_name" {
  description = "The username for the created user."
  value       = aws_identitystore_user.sso_user.user_name
}

# AWS IAM Identity Center 로그인 URL 출력
output "sso_login_url" {
  description = "The login URL for AWS IAM Identity Center (SSO)."
  value       = "https://${var.identity_store_id}.awsapps.com/start"
}
