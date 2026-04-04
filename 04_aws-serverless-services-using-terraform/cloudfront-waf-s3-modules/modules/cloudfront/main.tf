# AWS가 미리 만들어 둔 "캐싱 최적화" 정책을 이름으로 가져옵니다.
# 캐싱(Caching): 자주 요청되는 파일을 가까운 서버에 임시 저장해 빠르게 응답하는 기술
# 숫자 ID를 직접 쓰는 것보다 이름을 쓰면 코드를 읽는 사람이 어떤 정책인지 바로 알 수 있습니다.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# OAC(Origin Access Control): CloudFront만 S3 버킷에 접근할 수 있도록 허가증을 만드는 설정입니다.
# 이 설정이 없으면 S3 버킷 주소를 아는 사람 누구나 직접 파일을 볼 수 있어 보안에 취약합니다.
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${var.bucket_name}-oac" # 허가증 이름 (버킷 이름 기반으로 자동 생성)
  description                       = "OAC for CloudFront to S3 access"
  origin_access_control_origin_type = "s3"     # 오리진(파일 원본 위치)이 S3라는 것을 지정
  signing_behavior                  = "always" # 모든 요청에 항상 서명을 붙여서 S3에 전달
  signing_protocol                  = "sigv4"  # AWS 표준 서명 방식(SigV4) 사용
}

# CloudFront 배포(Distribution)를 생성합니다.
# CloudFront: 전 세계 200개 이상의 거점 서버(엣지 로케이션)를 통해 웹사이트를 빠르게 전달하는 AWS 서비스
# WAF와 연결하여 악의적인 요청을 미리 차단한 후 콘텐츠를 제공합니다.
resource "aws_cloudfront_distribution" "s3_distribution" {
  # 오리진(Origin): CloudFront가 실제 파일을 가져올 원본 위치(여기서는 S3)를 설정합니다.
  origin {
    domain_name              = var.bucket_domain_name                      # S3 지역 엔드포인트 (OAC에는 반드시 지역 엔드포인트 사용)
    origin_id                = "S3-${var.bucket_id}"                       # 이 오리진을 구분하는 고유 식별자
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id # 위에서 만든 OAC 허가증 연결
  }

  enabled             = true               # CloudFront 배포를 활성화
  default_root_object = var.index_document # 도메인 루트(/)에 접속하면 보여줄 기본 파일 (예: index.html)

  # HTTPS 인증서 설정 — CloudFront 기본 도메인(*.cloudfront.net)에 대한 무료 인증서를 사용합니다.
  viewer_certificate {
    cloudfront_default_certificate = true # 커스텀 도메인 없이 기본 CloudFront 인증서 사용
  }

  # 방문자 요청을 어떻게 처리할지 기본 규칙을 설정합니다.
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]       # 웹사이트 조회에 사용하는 HTTP 메서드만 허용
    cached_methods   = ["GET", "HEAD"]       # 이 메서드의 응답만 캐시에 저장
    target_origin_id = "S3-${var.bucket_id}" # 위에서 정의한 S3 오리진과 연결

    # AWS 공식 캐싱 최적화 정책 사용 — TTL, 압축 등이 웹사이트에 최적화되어 있습니다.
    # 하드코딩 대신 data source로 가져와 가독성과 유지보수성을 높였습니다.
    cache_policy_id = data.aws_cloudfront_cache_policy.caching_optimized.id

    # HTTP로 접속하면 자동으로 HTTPS로 이동시킵니다. (보안 강화)
    viewer_protocol_policy = "redirect-to-https"

    # 파일을 압축(gzip/brotli)해서 전송합니다. 용량이 줄어 웹사이트가 더 빠르게 열립니다.
    compress = true
  }

  # 존재하지 않는 페이지 요청 시 에러 처리 설정입니다.
  # S3 버킷이 비공개이므로 없는 파일 요청 시 S3가 403(접근 거부)을 반환합니다.
  # 방문자에게 403 대신 우리가 만든 에러 페이지를 404(페이지 없음)로 보여줍니다.
  custom_error_response {
    error_code         = 403                      # S3에서 403 오류가 오면
    response_code      = 404                      # 방문자에게는 404로 표시하고
    response_page_path = "/${var.error_document}" # 이 에러 페이지를 보여줍니다
  }

  # 특정 국가에서의 접근을 차단하는 지역 제한 설정입니다. 여기서는 제한 없이 전 세계 허용합니다.
  restrictions {
    geo_restriction {
      restriction_type = "none" # 지역 제한 없음 — 전 세계 어디서나 접근 가능
    }
  }

  tags = {
    Name = "${var.bucket_name}-cloudfront"
  }

  # 위에서 만든 WAF 웹 ACL을 이 CloudFront 배포에 연결합니다.
  # 이렇게 하면 모든 요청이 CloudFront에 도달하기 전에 WAF에서 먼저 필터링됩니다.
  web_acl_id = aws_wafv2_web_acl.web_acl.arn
}

# S3 버킷 정책 — "오직 이 CloudFront 배포만 S3 파일을 읽을 수 있다"는 규칙입니다.
# 이 정책이 없으면 다른 CloudFront 배포나 다른 서비스에서도 S3에 접근할 수 있습니다.
resource "aws_s3_bucket_policy" "static_site_policy" {
  bucket = var.bucket_id # 정책을 적용할 S3 버킷

  policy = jsonencode({
    Version = "2012-10-17",
    Id      = "PolicyForCloudFrontPrivateContent",
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal",
        Effect = "Allow", # 아래 조건을 만족하는 요청만 허용
        Principal = {
          Service = "cloudfront.amazonaws.com" # CloudFront 서비스에서 온 요청
        },
        Action   = "s3:GetObject",        # 파일 읽기(다운로드) 권한만 부여
        Resource = "${var.bucket_arn}/*", # 이 버킷의 모든 파일에 적용
        Condition = {
          StringEquals = {
            # 정확히 이 CloudFront 배포 ARN에서 온 요청만 허용 (다른 배포는 차단)
            "AWS:SourceArn" = "${aws_cloudfront_distribution.s3_distribution.arn}"
          }
        }
      }
    ]
  })
}

# WAF(Web Application Firewall) 웹 ACL을 생성합니다.
# WAF는 웹사이트 앞에 세워진 보안 검문소 역할을 합니다.
# SQL 인젝션, XSS 같은 해킹 시도를 자동으로 감지하고 차단합니다.
# CloudFront용 WAF는 반드시 us-east-1 리전에서 생성해야 합니다.
resource "aws_wafv2_web_acl" "web_acl" {
  name        = "${var.bucket_name}-web-acl"
  description = "WAF for CloudFront to protect ${var.bucket_name}"
  scope       = "CLOUDFRONT" # CloudFront에 연결할 WAF임을 지정

  # 기본 동작: 아래 규칙에 해당하지 않는 요청은 모두 허용합니다.
  default_action {
    allow {}
  }

  # 규칙 1: AWS 공통 보안 규칙 그룹
  # XSS(크로스 사이트 스크립팅), Log4J 취약점 등 일반적인 웹 공격을 차단합니다.
  rule {
    name     = "AWS-CommonRules"
    priority = 1 # 숫자가 낮을수록 먼저 평가됩니다

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet" # AWS가 관리하는 공통 보안 규칙 그룹
        vendor_name = "AWS"
      }
    }

    # override_action을 none으로 설정하면 규칙 그룹 자체의 동작(차단/허용)을 그대로 따릅니다.
    override_action {
      none {}
    }

    # CloudWatch를 통해 WAF 동작을 모니터링하기 위한 설정입니다.
    # CloudWatch: AWS에서 제공하는 모니터링 및 로그 관리 서비스
    visibility_config {
      sampled_requests_enabled   = true # 실제 요청 샘플을 CloudWatch에 저장
      cloudwatch_metrics_enabled = true # CloudWatch 메트릭 수집 활성화
      metric_name                = "${var.bucket_name}-waf-metric"
    }
  }

  # 규칙 2: SQL 인젝션 차단 규칙 그룹
  # SQL 인젝션: 악의적인 SQL 코드를 입력해 데이터베이스를 공격하는 해킹 기법
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 2

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet" # AWS가 관리하는 SQL 인젝션 차단 규칙 그룹
        vendor_name = "AWS"
      }
    }

    override_action {
      none {}
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.bucket_name}-waf-metric"
    }
  }

  # 웹 ACL 전체에 대한 CloudWatch 모니터링 설정입니다.
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.bucket_name}-web-acl-metric"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.bucket_name}-waf"
  }
}
