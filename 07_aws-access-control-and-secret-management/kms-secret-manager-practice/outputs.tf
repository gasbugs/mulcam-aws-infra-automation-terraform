# EC2 인스턴스의 공인 IP 주소 출력
output "ec2_public_ip" {
  description = "EC2 인스턴스의 공인 IP 주소"
  value       = aws_instance.ec2_instance.public_ip
}

# SSH를 통해 EC2 인스턴스에 바로 접속할 수 있는 명령어 출력
output "c01_ec2_ssh_command" {
  description = "EC2 인스턴스에 SSH로 접속하는 명령어"
  value       = "ssh -i ${var.key_path} ec2-user@${aws_instance.ec2_instance.public_ip}"
}


# aws 명령으로 secret manager에 저장된 database를 확인
output "c02_get_database_password" {
  description = "aws 명령으로 secret manager에 저장된 database를 확인"
  value       = "aws secretsmanager get-secret-value --secret-id '${aws_rds_cluster.my_aurora_cluster.master_user_secret[0].secret_arn}'"
}


# mysql 접속 명령어
output "c03_connect_mysql" {
  description = "mysql 접속 명령어 "
  value       = "mysql -h ${aws_rds_cluster.my_aurora_cluster.endpoint} -u ${var.db_username} -p"
}
