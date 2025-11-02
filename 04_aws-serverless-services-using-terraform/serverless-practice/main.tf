# 랜덤 문자열 생성
resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "random_integer" "random_suffix" {
  min = 1000
  max = 9999
}

###########################################
# 1. S3 버킷 생성 및 Lambda 코드 업로드
resource "aws_s3_bucket" "lambda_code" {
  # S3 버킷 이름: {팀 이름 또는 이니셜}-lambda-code-{random}
  bucket = "your-team-name-lambda-code-${random_string.bucket_suffix.result}"

  # 태그: Name, Environment(dev 또는 prod)
  tags = {
    Name        = "Lambda Code Bucket"
    Environment = "dev"
  }
}

# 버전 관리 활성화
resource "aws_s3_bucket_versioning" "lambda_code" {
  bucket = aws_s3_bucket.lambda_code.id
  versioning_configuration {
    status = "Enabled"
  }
}

# 퍼블릭 액세스 차단
resource "aws_s3_bucket_public_access_block" "lambda_code" {
  bucket = aws_s3_bucket.lambda_code.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "archive_file" "lambda_hello_world" {
  type = "zip"

  source_dir  = "${path.module}/hello-world"
  output_path = "${path.module}/index.zip"
}

# index.zip 파일을 S3에 업로드
resource "aws_s3_object" "lambda_code" {
  bucket = aws_s3_bucket.lambda_code.id

  key    = "index.zip"
  source = data.archive_file.lambda_hello_world.output_path

  etag = filemd5(data.archive_file.lambda_hello_world.output_path)
}

###########################################
# 2. Lambda 함수 생성 및 설정
resource "aws_lambda_function" "my_serverless_function" {
  # 함수 이름: my-serverless-function
  function_name = "my-serverless-function"
  s3_bucket     = aws_s3_bucket.lambda_code.id
  s3_key        = aws_s3_object.lambda_code.key
  handler       = "index.handler" # 핸들러: index.handler
  runtime       = "nodejs20.x"    # 런타임: nodejs20.x
  memory_size   = 128             # 메모리: 최소 128MB
  timeout       = 30              # 타임아웃: 30초
  role          = aws_iam_role.lambda_execution_role.arn

  # 환경 변수: STAGE=dev
  environment {
    variables = {
      STAGE = "dev"
    }
  }
}

# Lambda 실행 역할 생성
resource "aws_iam_role" "lambda_execution_role" {
  name = "lambda_execution_role_${random_integer.random_suffix.result}" # 실행 역할 이름 생성

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
}

# Lambda에 대한 기본 실행 역할 정책 연결
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_execution_role.name                            # 연결할 IAM 역할 이름
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" # Lambda 실행에 필요한 기본 정책
}

###########################################
# 3. API Gateway를 통한 Lambda 노출
# API Gateway 생성
resource "aws_apigatewayv2_api" "my_api" {
  name          = "serverless-api" # API 이름 API Gateway REST API 이름: serverless-api
  protocol_type = "HTTP"           # 프로토콜 타입 (HTTP)
}

# APIGW와 Lambda 통합 설정
resource "aws_apigatewayv2_integration" "my_lambda_integration" {
  api_id                 = aws_apigatewayv2_api.my_api.id                        # API ID
  integration_type       = "AWS_PROXY"                                           # 통합 타입 (AWS 프록시)
  integration_uri        = aws_lambda_function.my_serverless_function.invoke_arn # 통합할 Lambda 함수의 ARN
  payload_format_version = "2.0"                                                 # 페이로드 형식 버전
}

# API Gateway 라우트 규칙 설정
resource "aws_apigatewayv2_route" "my_route" {
  api_id    = aws_apigatewayv2_api.my_api.id                                          # API ID
  route_key = "GET /"                                                                 # 기본 경로(/)에 GET 요청 처리 리소스 생성
  target    = "integrations/${aws_apigatewayv2_integration.my_lambda_integration.id}" # 통합 대상
}

# API Gateway에 Lambda 실행 권한 부여
# API Gateway가 Lambda 호출 가능하도록 IAM 역할 생성
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"                           # 정책 식별자
  action        = "lambda:InvokeFunction"                                  # 허용할 액션
  function_name = aws_lambda_function.my_serverless_function.function_name # Lambda 함수 이름
  principal     = "apigateway.amazonaws.com"                               # 허용할 주체 (API Gateway)

  source_arn = "${aws_apigatewayv2_api.my_api.execution_arn}/*/*" # API Gateway ARN
}

# API Gateway 스테이지 설정 (dev 환경)
# 경로에 dev를 통해서 요청하도록 구성 가능
# https://vrkiu58szg.execute-api.us-east-1.amazonaws.com/dev/hello
resource "aws_apigatewayv2_stage" "dev" {
  api_id      = aws_apigatewayv2_api.my_api.id # API ID
  name        = "dev"                          # 스테이지 이름 (dev)
  auto_deploy = true                           # 자동 배포 활성화
}

# API Gateway 스테이지 설정 (default 환경)
# 경로에 스테이지를 생략해서 요청하도록 구성 가능
# https://vrkiu58szg.execute-api.us-east-1.amazonaws.com/hello
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.my_api.id # API ID
  name        = "$default"                     # 스테이지 이름 ($default)
  auto_deploy = true                           # 자동 배포 활성화
}

###########################################
# 4. CloudFront 배포 생성 및 Lambda 통합
resource "aws_cloudfront_distribution" "api_distribution" {
  origin {
    domain_name = replace(aws_apigatewayv2_stage.default.invoke_url, "/^https?://([^/]*).*/", "$1")
    origin_id   = "APIGateway" # 오리진으로 API Gateway 엔드포인트 설정

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only" # HTTPS로 리디렉션 설정
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = ""

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "APIGateway"

    forwarded_values {
      query_string = true
      headers      = ["Origin", "Access-Control-Request-Headers", "Access-Control-Request-Method"]

      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0 # 기본 TTL 0으로 설정 (최신 응답 유지)
    max_ttl                = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  # Web ACL을 CloudFront 배포와 연결
  web_acl_id = aws_wafv2_web_acl.serverless_waf.arn
}

# 5. Route 53에서 도메인 이름으로 CloudFront 배포 연결
##########################################################################
# VPC 설정
##########################################################################
locals {
  my_zone = "us-east-1"
  aws_zone_mapping = {
    "us-east-1"      = ["a", "b", "c"]
    "ap-northeast-2" = ["a", "b", "c"]

  }
  azs = [for az in local.aws_zone_mapping[local.my_zone] : "${local.my_zone}${az}"]
}

module "my_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name = "my-vpc"
  cidr = "10.0.0.0/16"

  azs             = local.azs
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = false
  single_nat_gateway = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

resource "aws_route53_zone" "main" {
  name = "your-domain.com" # Hosted Zone 생성 및 사용자 지정 도메인 생성
  vpc {
    vpc_id     = module.my_vpc.vpc_id
    vpc_region = local.my_zone
  }
}

resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "api.your-domain.com"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.api_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.api_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

# 6. WAF를 사용하여 보안 규칙 설정
resource "aws_wafv2_web_acl" "serverless_waf" {
  name  = "serverless-waf" # Web ACL 이름: serverless-waf
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # AWS 관리형 규칙 그룹(AWSManagedRulesCommonRuleSet) 사용
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "ServerlessWAFMetric"
    sampled_requests_enabled   = true
  }
}

# 7. 추가 과제: 서버리스 환경의 모니터링 및 관리
# CloudWatch 로그 그룹 생성, Lambda 로그 수집 및 모니터링
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.my_serverless_function.function_name}"
  retention_in_days = 14
}

# SNS 토픽 생성
resource "aws_sns_topic" "lambda_errors" {
  name = "lambda-errors-topic"
}

# SNS 토픽 구독 생성 (이메일 알림을 위한 예시)
resource "aws_sns_topic_subscription" "lambda_errors_email" {
  topic_arn = aws_sns_topic.lambda_errors.arn
  protocol  = "email"
  endpoint  = "your-email@example.com"
}

# CloudWatch 알람 리소스 정의 (Lambda 함수 에러 감시)
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "lambda-errors"                      # 알람 이름 지정
  comparison_operator = "GreaterThanThreshold"               # 임계값보다 크면 알람 발생
  evaluation_periods  = "1"                                  # 1번의 평가 기간 동안 조건 충족 시 알람
  metric_name         = "Errors"                             # 감시할 메트릭 이름 (Lambda 에러)
  namespace           = "AWS/Lambda"                         # 메트릭 네임스페이스 (Lambda)
  period              = "60"                                 # 평가 주기(초), 1분마다 집계
  statistic           = "Sum"                                # 해당 기간 동안의 합계로 평가
  threshold           = "0"                                  # 임계값: 0 (에러가 1건이라도 발생하면 알람)
  alarm_description   = "This metric monitors lambda errors" # 알람 설명
  alarm_actions       = [aws_sns_topic.lambda_errors.arn]    # 알람 발생 시 알림을 보낼 SNS 토픽

  dimensions = {
    FunctionName = aws_lambda_function.my_serverless_function.function_name # 감시 대상 Lambda 함수 이름 지정
  }
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "ServerlessDashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.my_serverless_function.function_name],
            [".", "Errors", ".", "."],
            ["AWS/ApiGateway", "Count", "ApiName", aws_apigatewayv2_api.my_api.name]
          ]
          view    = "timeSeries"
          stacked = false
          region  = local.my_zone
          title   = "Lambda and API Gateway Metrics"
        }
      }
    ]
  })
}
