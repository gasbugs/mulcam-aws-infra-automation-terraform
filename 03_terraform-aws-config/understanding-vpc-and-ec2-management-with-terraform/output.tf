output "ec2_domain" {
  value = aws_instance.my_ec2.public_dns
}
