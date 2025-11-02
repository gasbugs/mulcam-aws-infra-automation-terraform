# outputs.tf

# 생성된 Lambda 함수 이름 출력
output "lambda_function_name" {
  description = "생성된 Lambda 함수의 이름"
  value       = aws_lambda_function.my_lambda.function_name
}

# API Gateway의 엔드포인트 URL 출력
output "api_endpoint" {
  description = "API Gateway의 엔드포인트 URL"
  value       = aws_apigatewayv2_stage.dev.invoke_url
}

# S3 버킷 이름 출력
output "s3_bucket_name" {
  description = "Lambda 코드를 업로드한 S3 버킷의 이름"
  value       = aws_s3_bucket.lambda_bucket.bucket
}
