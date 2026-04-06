output "ec2_instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.ec2_instance.id
}

output "ec2_instance_private_ip" {
  description = "Private IP of the EC2 instance"
  value       = aws_instance.ec2_instance.private_ip
}

output "ec2_instance_public_ip" {
  description = "Public IP of the EC2 instance (if allocated)"
  value       = aws_instance.ec2_instance.public_dns
}

output "ec2_security_group_id" {
  description = "Security group ID of the EC2 instance"
  value       = aws_security_group.ec2_sg.id
}
