# 출력값 정의 — EC2 접속에 필요한 정보

# EC2 인스턴스의 공인 IP 주소 출력
output "ec2_public_ip" {
  description = "EC2 인스턴스의 공인 IP 주소"
  value       = aws_instance.ec2_instance.public_ip
}

# SSH 접속 명령어 안내
output "ssh_command" {
  description = "EC2 SSH 접속 명령어 예시"
  value       = "ssh -i ec2-key.pem ec2-user@${aws_instance.ec2_instance.public_ip}"
}

# EC2 SSH 접속용 프라이빗 키 출력
output "private_key_pem" {
  description = "EC2 SSH 접속용 프라이빗 키 (민감 정보 — terraform output -raw private_key_pem으로 확인)"
  value       = tls_private_key.ec2_key.private_key_pem
  sensitive   = true
}
