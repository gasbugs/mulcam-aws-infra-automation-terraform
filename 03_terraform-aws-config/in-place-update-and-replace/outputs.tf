output "ec2_domain" {
  value = aws_instance.my_ec2.public_dns # 생성된 EC2 인스턴스의 퍼블릭 DNS 출력
}

output "web_url" {
  value = "http://${aws_instance.my_ec2.public_dns}" # 웹 서버 접속 URL
}

output "private_key_pem" {
  value     = tls_private_key.my_key.private_key_pem # SSH 접속용 프라이빗 키
  sensitive = true
}
