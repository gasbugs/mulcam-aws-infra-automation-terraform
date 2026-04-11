# 출력값 정의 — EC2 접속 및 Aurora DB 연결에 필요한 정보

# EC2 인스턴스의 공인 IP 주소 출력
output "ec2_public_ip" {
  description = "EC2 인스턴스의 공인 IP 주소"
  value       = aws_instance.ec2_instance.public_ip
}

# SSH를 통해 EC2 인스턴스에 바로 접속할 수 있는 명령어 출력
output "c01_ec2_ssh_command" {
  description = "EC2 인스턴스에 SSH로 접속하는 명령어 (ec2-key.pem 파일 사용)"
  value       = "ssh -i ec2-key.pem ec2-user@${aws_instance.ec2_instance.public_ip}"
}

# AWS 명령으로 Secrets Manager에 저장된 데이터베이스 비밀번호를 확인
output "c02_get_database_password" {
  description = "AWS CLI 명령으로 Secrets Manager에 저장된 Aurora DB 비밀번호 확인"
  value       = "aws secretsmanager get-secret-value --secret-id '${aws_rds_cluster.my_aurora_cluster.master_user_secret[0].secret_arn}'"
}

# MySQL 접속 명령어
output "c03_connect_mysql" {
  description = "Aurora MySQL 클러스터에 접속하는 명령어"
  value       = "mysql -h ${aws_rds_cluster.my_aurora_cluster.endpoint} -u ${var.db_username} -p"
}

# EC2 SSH 접속용 프라이빗 키 출력
output "private_key_pem" {
  description = "EC2 SSH 접속용 프라이빗 키 (민감 정보 — terraform output -raw private_key_pem으로 확인)"
  value       = tls_private_key.ec2_key.private_key_pem
  sensitive   = true
}
