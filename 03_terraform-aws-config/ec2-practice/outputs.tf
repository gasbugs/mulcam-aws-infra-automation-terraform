output "ec2_public_dns" {
  description = "생성된 EC2 인스턴스의 퍼블릭 DNS"
  value       = aws_instance.my_ec2.public_dns
}

output "ec2_for_each_public_dns" {
  description = "for_each로 생성된 EC2 인스턴스의 퍼블릭 DNS"
  value       = { for k, v in aws_instance.my_ec2_for_each : k => v.public_dns }
}

output "private_key_path" {
  description = "생성된 SSH 개인 키 파일 경로"
  value       = local_file.private_key.filename
}
