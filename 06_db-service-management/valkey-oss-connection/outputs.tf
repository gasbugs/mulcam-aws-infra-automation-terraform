output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table"
  value       = module.dynamodb.dynamodb_table_name
}

output "redis_cluster_endpoint" {
  description = "Endpoint of the Redis cluster"
  value       = module.redis.redis_cluster_endpoint
}

output "ec2_instance_id" {
  description = "EC2 instance ID"
  value       = module.ec2.ec2_instance_id
}

output "ec2_instance_private_ip" {
  description = "Private IP of the EC2 instance"
  value       = module.ec2.ec2_instance_private_ip
}

output "ec2_instance_public_ip" {
  description = "Public IP of the EC2 instance"
  value       = module.ec2.ec2_instance_public_ip
}
