# EC2 인스턴스 ID 출력
output "instance_id" {
  description = "The ID of the EC2 instance"
  value       = aws_instance.web_server.id
}

# EC2 인스턴스 공개 IP 출력
output "instance_public_ip" {
  description = "The public IP address of the EC2 instance"
  value       = aws_instance.web_server.public_ip
}

# EC2 인스턴스 태그 출력
output "instance_tags" {
  description = "Tags associated with the EC2 instance"
  value       = aws_instance.web_server.tags
}
