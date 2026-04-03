output "ec2_public_dns" {
  description = "생성된 EC2 인스턴스의 퍼블릭 DNS"
  value       = { for k, v in aws_instance.my_ec2 : k => v.public_dns }
}

output "private_key_path" {
  description = "생성된 SSH 개인 키 파일 경로"
  value       = local_file.private_key.filename
}
