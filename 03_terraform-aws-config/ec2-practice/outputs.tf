output "ec2_domain" {
  value = aws_instance.my_ec2[*].public_dns # 생성된 EC2 인스턴스의 퍼블릭 DNS 출력
}
