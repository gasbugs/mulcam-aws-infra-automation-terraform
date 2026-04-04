# outputs.tf

# 생성된 Lambda 함수 이름 출력
output "lambda_function_name" {
  description = "생성된 Lambda 함수의 이름"
  value       = aws_lambda_function.my_lambda.function_name
}

# API Gateway dev 스테이지 엔드포인트 URL 출력
# 호출 예: https://<id>.execute-api.us-east-1.amazonaws.com/dev/hello
output "api_endpoint_dev" {
  description = "API Gateway dev 스테이지 엔드포인트 URL"
  value       = aws_apigatewayv2_stage.dev.invoke_url
}

# API Gateway default 스테이지 엔드포인트 URL 출력
# 호출 예: https://<id>.execute-api.us-east-1.amazonaws.com/hello
output "api_endpoint_default" {
  description = "API Gateway default 스테이지 엔드포인트 URL"
  value       = aws_apigatewayv2_stage.default.invoke_url
}

# S3 버킷 이름 출력
output "s3_bucket_name" {
  description = "Lambda 코드를 업로드한 S3 버킷의 이름"
  value       = aws_s3_bucket.lambda_bucket.bucket
}
