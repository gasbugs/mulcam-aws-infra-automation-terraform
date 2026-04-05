output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.ec2_instance.id
}

output "public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.ec2_instance.public_ip
}

output "public_dns" {
  description = "Public domain of the EC2 instance"
  value       = aws_instance.ec2_instance.public_dns
}

# SSH 접속 시 사용할 프라이빗 키 파일 경로
output "private_key_path" {
  description = "Path to the generated SSH private key file"
  value       = local_file.ec2_private_key.filename
}
