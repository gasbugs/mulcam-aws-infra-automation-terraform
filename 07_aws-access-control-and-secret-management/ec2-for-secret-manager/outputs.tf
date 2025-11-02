# EC2 인스턴스의 공인 IP 주소 출력
output "ec2_public_ip" {
  description = "EC2 인스턴스의 공인 IP 주소"
  value       = aws_instance.ec2_instance.public_ip
}

# SSH를 통해 EC2 인스턴스에 바로 접속할 수 있는 명령어 출력
output "ec2_ssh_command" {
  description = "EC2 인스턴스에 SSH로 접속하는 명령어"
  value       = "ssh -i ${var.key_path} ec2-user@${aws_instance.ec2_instance.public_ip}"
}
