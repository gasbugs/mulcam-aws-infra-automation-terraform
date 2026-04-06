output "dynamodb_table_name" {
  description = "Name of the DynamoDB table"
  value       = aws_dynamodb_table.main_table.name
}

output "dynamodb_table_arn" {
  description = "ARN of the DynamoDB table"
  value       = aws_dynamodb_table.main_table.arn
}

output "dynamodb_endpoint_id" {
  description = "ID of the VPC Gateway Endpoint for DynamoDB"
  value       = aws_vpc_endpoint.dynamodb_endpoint.id
}

output "ec2_instance_profile" {
  description = "ec2에 부여할 dynamodb 접근 프로파일"
  value       = aws_iam_instance_profile.ec2_instance_profile.name
}
