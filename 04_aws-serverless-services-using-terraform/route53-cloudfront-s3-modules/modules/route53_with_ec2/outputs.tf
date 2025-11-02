# 생성된 키 페어 이름 출력
output "key_pair_name" {
  description = "The name of the generated key pair."
  value       = aws_key_pair.generated_key_pair.key_name
}

# EC2 인스턴스의 퍼블릭 IP 출력 (SSH 연결을 위해)
output "ec2_public_ip" {
  description = "The public IP address of the EC2 instance."
  value       = aws_instance.dns_test_instance.public_ip
}

# EC2 인스턴스의 퍼블릭 DNS 출력 (SSH 연결을 위해)
output "ec2_public_dns" {
  description = "The public DNS of the EC2 instance."
  value       = aws_instance.dns_test_instance.public_dns
}

# Private Hosted Zone의 ID 출력
output "private_dns_zone_id" {
  description = "The ID of the created private DNS hosted zone."
  value       = aws_route53_zone.private_dns.zone_id
}
