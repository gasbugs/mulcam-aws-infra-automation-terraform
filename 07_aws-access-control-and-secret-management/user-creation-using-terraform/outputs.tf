# 생성된 IAM 유저의 이름 출력
output "ec2_user_name" {
  description = "생성된 IAM 사용자의 이름"
  value       = aws_iam_user.ec2_user.name
}

# 생성된 IAM 그룹의 이름 출력
output "ec2_group_name" {
  description = "생성된 IAM 그룹의 이름"
  value       = aws_iam_group.ec2_managers.name
}

# Access Key ID 출력
output "ec2_user_access_key_id" {
  description = "IAM 사용자의 Access Key ID (AWS CLI 설정에 사용)"
  value       = aws_iam_access_key.ec2_user_key.id
}

# Secret Access Key 출력
output "ec2_user_secret_access_key" {
  description = "IAM 사용자의 Secret Access Key (최초 1회만 조회 가능)"
  value       = aws_iam_access_key.ec2_user_key.secret
  sensitive   = true # 민감한 정보이므로 출력 시 마스킹 처리
}
