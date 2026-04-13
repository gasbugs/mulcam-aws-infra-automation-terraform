# EC2 인스턴스 ID 출력 — AWS 콘솔에서 인스턴스를 찾을 때 사용
output "instance_id" {
  description = "EC2 인스턴스 ID"
  value       = aws_instance.main.id
}

# 공인 IP 주소 출력 — SSH 접속 및 브라우저 접속에 사용
output "public_ip" {
  description = "EC2 인스턴스의 공인 IP 주소"
  value       = aws_instance.main.public_ip
}

# SSH 접속 명령어 — 터미널에 그대로 붙여넣어 바로 접속 가능
output "ssh_command" {
  description = "EC2 SSH 접속 명령어 — 터미널에 그대로 붙여넣어 실행"
  value       = "ssh -i docker-basics-key.pem ec2-user@${aws_instance.main.public_ip}"
}

# HTTP 접속 URL — 도커로 웹 서버 실행 후 브라우저 확인 시 사용
output "http_url" {
  description = "HTTP 접속 URL — 도커 웹 서버 실행 후 브라우저에서 확인"
  value       = "http://${aws_instance.main.public_ip}"
}

# 프라이빗 키 PEM — terraform output -raw private_key_pem 명령으로 추출 가능
output "private_key_pem" {
  description = "SSH 접속용 프라이빗 키 (민감 정보) — terraform output -raw private_key_pem 으로 확인"
  value       = tls_private_key.main.private_key_pem
  sensitive   = true
}

# Docker 설치 확인 명령어 — SSH 접속 후 Docker 동작 여부 확인
output "docker_check_command" {
  description = "SSH 접속 후 Docker 설치 및 동작 확인 명령어"
  value       = "ssh -i docker-basics-key.pem ec2-user@${aws_instance.main.public_ip} 'docker version && docker run hello-world'"
}
