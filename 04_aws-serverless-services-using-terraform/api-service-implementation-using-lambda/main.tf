# main.tf

# 공통 태그 정의
locals {
  common_tags = {
    Environment = var.environment
    Project     = "lambda-hello-world"
    ManagedBy   = "terraform"
  }
}

# 랜덤한 숫자 생성 (IAM Role과 S3 이름에 사용)
resource "random_integer" "random_suffix" {
  min = 1000
  max = 9999
  keepers = {
    project = "lambda-hello-world" # 고정값으로 재생성 방지
  }
}


##########################################################
# IAM 역할 및 정책 구성 (Lambda보다 먼저 선언)

# Lambda 실행 역할 생성
resource "aws_iam_role" "lambda_execution_role" {
  name = "${var.environment}-lambda-execution-role-${random_integer.random_suffix.result}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com" # Lambda 서비스에 역할 위임
        },
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

# Lambda에 대한 기본 실행 역할 정책 연결
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  # AWSLambdaBasicExecutionRole 정책은 Lambda가 CloudWatch Logs에 로그를 쓸 수 있도록 허용
}

# S3 읽기 권한 정책 생성
resource "aws_iam_policy" "lambda_s3_policy" {
  name        = "${var.environment}-lambda-s3-policy-${random_integer.random_suffix.result}"
  path        = "/"
  description = "IAM policy for Lambda to read from S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = [
          "${aws_s3_bucket.lambda_bucket.arn}/*"
        ]
      }
    ]
  })

  tags = local.common_tags
}

# Lambda 실행 역할에 S3 읽기 정책 연결
resource "aws_iam_role_policy_attachment" "lambda_s3" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = aws_iam_policy.lambda_s3_policy.arn
}


##########################################################
# 코드 파일 업로드

# S3 버킷 생성
resource "aws_s3_bucket" "lambda_bucket" {
  bucket = "python-resource-${random_integer.random_suffix.result}"

  tags = local.common_tags
}

# S3 버킷 퍼블릭 접근 차단
resource "aws_s3_bucket_public_access_block" "lambda_bucket" {
  bucket                  = aws_s3_bucket.lambda_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ZIP 파일 생성 (hello-world.zip)
data "archive_file" "lambda_hello_world" {
  type        = "zip"
  source_dir  = "${path.module}/hello-world"
  output_path = "${path.module}/hello-world.zip"
}

# S3에 Lambda 함수 코드 업로드
resource "aws_s3_object" "lambda_hello_world" {
  bucket = aws_s3_bucket.lambda_bucket.id
  key    = "hello-world.zip"
  source = data.archive_file.lambda_hello_world.output_path
  etag   = filemd5(data.archive_file.lambda_hello_world.output_path)
}


##########################################################
# Lambda 함수 생성

resource "aws_lambda_function" "my_lambda" {
  function_name = "${var.environment}-hello-world"
  handler       = "lambda_function.handler"
  # 람다는 파이썬 외, Java, Node.js, Go 등 다양한 런타임 지원
  runtime = "python3.12" # python3.10은 2025년 11월 Lambda 지원 종료
  role    = aws_iam_role.lambda_execution_role.arn

  s3_bucket = aws_s3_bucket.lambda_bucket.id
  s3_key    = aws_s3_object.lambda_hello_world.key

  source_code_hash = data.archive_file.lambda_hello_world.output_base64sha256

  timeout     = 10  # 초 단위
  memory_size = 128 # MB 단위

  tags = local.common_tags
}

# CloudWatch 로그 그룹 생성
resource "aws_cloudwatch_log_group" "hello_world" {
  name              = "/aws/lambda/${aws_lambda_function.my_lambda.function_name}"
  retention_in_days = 30

  tags = local.common_tags
}


##########################################################
# API Gateway 구성

# API Gateway 생성
resource "aws_apigatewayv2_api" "my_api" {
  name          = "${var.environment}-api"
  protocol_type = "HTTP"

  tags = local.common_tags
}

# APIGW와 Lambda 통합 설정
resource "aws_apigatewayv2_integration" "my_lambda_integration" {
  api_id                 = aws_apigatewayv2_api.my_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.my_lambda.invoke_arn
  payload_format_version = "2.0"
}

# API Gateway 라우트 규칙 설정
resource "aws_apigatewayv2_route" "my_route" {
  api_id    = aws_apigatewayv2_api.my_api.id
  route_key = "GET /hello"
  target    = "integrations/${aws_apigatewayv2_integration.my_lambda_integration.id}"
}

# API Gateway에 Lambda 실행 권한 부여
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.my_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.my_api.execution_arn}/*/*"
}

# API Gateway 스테이지 설정 (dev 환경)
# https://<id>.execute-api.us-east-1.amazonaws.com/dev/hello
resource "aws_apigatewayv2_stage" "dev" {
  api_id      = aws_apigatewayv2_api.my_api.id
  name        = "dev"
  auto_deploy = true

  tags = local.common_tags
}

# API Gateway 스테이지 설정 (default 환경)
# https://<id>.execute-api.us-east-1.amazonaws.com/hello
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.my_api.id
  name        = "$default"
  auto_deploy = true

  tags = local.common_tags
}
