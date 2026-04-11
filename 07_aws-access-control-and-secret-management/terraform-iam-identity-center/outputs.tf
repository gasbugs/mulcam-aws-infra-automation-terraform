# 출력값 정의 — SSO 설정 완료 후 로그인에 필요한 정보

# 생성된 SSO 그룹의 고유 ID 출력
output "group_id" {
  description = "IAM Identity Store에 생성된 그룹의 고유 ID"
  value       = aws_identitystore_group.sso_group.group_id
}

# 생성된 SSO 사용자의 고유 ID 출력
output "user_id" {
  description = "IAM Identity Store에 생성된 사용자의 고유 ID"
  value       = aws_identitystore_user.sso_user.user_id
}

# 생성된 SSO 사용자의 로그인 이름 출력
output "user_name" {
  description = "SSO 로그인에 사용하는 사용자 이름 (username)"
  value       = aws_identitystore_user.sso_user.user_name
}

# AWS IAM Identity Center 로그인 URL 출력
output "sso_login_url" {
  description = "AWS IAM Identity Center(SSO) 로그인 포털 URL — 브라우저에서 접속하여 SSO 로그인 가능"
  value       = "https://${var.identity_store_id}.awsapps.com/start"
}
