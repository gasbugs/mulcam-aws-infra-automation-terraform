output "aws_ecr_repository_name" {
  description = "Name of the ECR repository created for practice"
  value       = aws_ecr_repository.main.name
}

output "aws_ecr_repository_url" {
  description = "Repository URL for pushing images into the practice ECR repository"
  value       = aws_ecr_repository.main.repository_url
}

output "docker_hub_pull_through_cache_rule" {
  description = "ECR pull-through cache prefix for Docker Hub images"
  value       = aws_ecr_pull_through_cache_rule.docker_hub.ecr_repository_prefix
}

output "instance_public_dns" {
  description = "Public DNS name of the EC2 instance used for validation"
  value       = aws_instance.main.public_dns
}

output "instance_id" {
  description = "Instance ID of the EC2 instance used for validation"
  value       = aws_instance.main.id
}

output "instance_ssh_private_key_pem" {
  description = "Generated private key for SSH access to the EC2 instance"
  value       = tls_private_key.instance.private_key_pem
  sensitive   = true
}
