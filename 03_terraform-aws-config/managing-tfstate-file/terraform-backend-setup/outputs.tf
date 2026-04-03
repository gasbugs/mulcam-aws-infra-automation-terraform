# outputs.tf

output "s3_bucket_name" {
  description = "생성된 Terraform 상태 파일 S3 버킷 이름"
  value       = aws_s3_bucket.terraform_state.bucket
}

output "dynamodb_table_name" {
  description = "생성된 Terraform 상태 잠금 DynamoDB 테이블 이름"
  value       = aws_dynamodb_table.terraform_lock.name
}
