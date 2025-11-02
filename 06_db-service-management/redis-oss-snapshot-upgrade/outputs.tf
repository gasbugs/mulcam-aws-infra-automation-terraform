output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "redis_cluster_endpoint" {
  description = "Endpoint of the Redis cluster"
  value       = module.redis.redis_cluster_endpoint
}
