output "ec2_domain" {
  value = aws_instance.my_ec2.public_dns
}

output "private_key_path" {
  value       = local_sensitive_file.private_key.filename
  description = "생성된 SSH 프라이빗 키 파일 경로"
}
