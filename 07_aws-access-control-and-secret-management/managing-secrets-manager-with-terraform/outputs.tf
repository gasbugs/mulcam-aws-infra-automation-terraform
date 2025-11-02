# 생성된 시크릿의 ARN 출력
output "secret_arn" {
  description = "The ARN of the created secret"
  value       = aws_secretsmanager_secret.example_secret.arn
}

# Lambda 함수 이름 출력
output "lambda_function_name" {
  description = "The name of the Lambda function created for secret rotation"
  value       = aws_lambda_function.rotate_secret.function_name
}
