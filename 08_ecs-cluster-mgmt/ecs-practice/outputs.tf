output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "capacity_provider_name" {
  description = "Name of the ECS capacity provider backed by the Auto Scaling group"
  value       = aws_ecs_capacity_provider.main.name
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.main.name
}
