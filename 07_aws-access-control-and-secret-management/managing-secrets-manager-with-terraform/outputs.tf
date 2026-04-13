# 출력값 정의 — Secrets Manager 실습 결과 확인에 필요한 정보

# 생성된 시크릿의 ARN 출력
output "secret_arn" {
  description = "생성된 Secrets Manager 시크릿의 고유 식별자(ARN) — 다른 서비스에서 이 시크릿을 참조할 때 사용"
  value       = aws_secretsmanager_secret.example_secret.arn
}

# Lambda 함수 이름 출력
output "lambda_function_name" {
  description = "시크릿 자동 교체를 담당하는 Lambda 함수의 이름"
  value       = aws_lambda_function.rotate_secret.function_name
}

# EC2 인스턴스의 공인 IP 주소 출력
output "ec2_public_ip" {
  description = "EC2 인스턴스의 공인 IP 주소 — SSH 접속 시 사용"
  value       = aws_instance.ec2_instance.public_ip
}

# SSH 접속 명령어 출력 — TLS 키와 EC2 IP를 조합하여 바로 사용 가능한 명령어 제공
output "ssh_command" {
  description = "EC2 SSH 접속 명령어 — 터미널에 그대로 붙여넣어 접속 가능"
  value       = "ssh -i ec2-key.pem ec2-user@${aws_instance.ec2_instance.public_ip}"
}

# EC2 SSH 접속용 프라이빗 키 출력 (민감 정보)
output "private_key_pem" {
  description = "EC2 SSH 접속용 프라이빗 키 — terraform output -raw private_key_pem 명령으로 확인"
  value       = tls_private_key.ec2_key.private_key_pem
  sensitive   = true
}

# EC2에서 시크릿을 조회하는 AWS CLI 명령어 출력
output "get_secret_command" {
  description = "EC2 접속 후 Secrets Manager에서 시크릿 값을 조회하는 AWS CLI 명령어"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.example_secret.id} --region ${var.aws_region} --query SecretString --output text"
}
