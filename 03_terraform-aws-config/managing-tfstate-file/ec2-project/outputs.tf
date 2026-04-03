# outputs.tf

output "instance_id" {
  description = "생성된 EC2 인스턴스 ID"
  value       = aws_instance.my_ec2.id
}

output "public_ip" {
  description = "EC2 인스턴스의 퍼블릭 IP"
  value       = aws_instance.my_ec2.public_ip
}

output "ami_id" {
  description = "사용된 AMI ID"
  value       = data.aws_ami.al2023.id
}
