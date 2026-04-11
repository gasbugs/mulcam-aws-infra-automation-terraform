# 출력값 정의 — Secrets Manager 실습 결과 확인에 필요한 정보

# 생성된 시크릿의 ARN 출력
output "secret_arn" {
  description = "생성된 Secrets Manager 시크릿의 고유 식별자(ARN) — 다른 서비스에서 이 시크릿을 참조할 때 사용"
  value       = aws_secretsmanager_secret.example_secret.arn
}

# Lambda 함수 이름 출력
output "lambda_function_name" {
  description = "시크릿 자동 교체를 담당하는 Lambda 함수의 이름"
  value       = aws_lambda_function.rotate_secret.function_name
}
