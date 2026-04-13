# WordPress 웹사이트 접속 주소 (로드밸런서 DNS)
output "lb_dns" {
  description = "DNS name of the WordPress ALB load balancer"
  value       = aws_lb.wordpress.dns_name
}
