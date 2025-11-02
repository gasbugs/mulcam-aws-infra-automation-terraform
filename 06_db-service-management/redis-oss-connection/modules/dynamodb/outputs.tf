output "dynamodb_table_name" {
  description = "Name of the DynamoDB table"
  value       = aws_dynamodb_table.main_table.name
}

output "dynamodb_table_arn" {
  description = "ARN of the DynamoDB table"
  value       = aws_dynamodb_table.main_table.arn
}

output "dynamodb_endpoint_id" {
  description = "ID of the VPC endpoint for DynamoDB"
  value       = aws_vpc_endpoint.dynamodb_endpoint.id
}

output "dynamodb_security_group_id" {
  description = "Security group ID for the DynamoDB VPC endpoint"
  value       = aws_security_group.dynamodb_sg.id
}

output "ec2_instance_profile" {
  description = "ec2에 부여할 dynamodb 접근 프로파일"
  value       = aws_iam_instance_profile.ec2_instance_profile.name
}
