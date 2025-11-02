output "aws_ecr_repository_url" {
  value = aws_ecr_repository.my_ecr_repo.name
}

output "aws_instance_url" {
  value = aws_instance.example.public_dns
}
