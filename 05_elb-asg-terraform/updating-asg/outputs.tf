# VPC ID 출력
output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

# 서브넷 ID들 출력
output "private_subnets" {
  description = "The IDs of the created subnets"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "The IDs of the created subnets"
  value       = module.vpc.public_subnets
}

# 오토 스케일링 그룹 이름 출력
output "autoscaling_group_name" {
  description = "The name of the Auto Scaling group"
  value       = aws_autoscaling_group.example.name
}

# 애플리케이션 로드 밸런서의 DNS 이름 출력
output "alb_dns_name" {
  description = "The DNS name of the Application Load Balancer"
  value       = aws_lb.example.dns_name
}

# Terraform이 생성한 SSH 프라이빗 키 출력 (민감 정보 - terraform output -raw private_key_pem 으로 확인)
output "private_key_pem" {
  description = "EC2 SSH 접속에 사용할 프라이빗 키 (PEM 형식). 파일로 저장 후 chmod 400 적용 필요"
  value       = tls_private_key.example.private_key_pem
  sensitive   = true # 민감 정보이므로 일반 출력 시 숨김 처리
}
