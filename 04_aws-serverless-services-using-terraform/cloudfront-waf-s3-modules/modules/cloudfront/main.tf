# CloudFront의 S3 접근을 위한 Origin Access Control 설정
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "S3-origin-access-control"        # Origin Access Control(OAC) 이름 설정
  description                       = "OAC for CloudFront to S3 access" # OAC 설명
  origin_access_control_origin_type = "s3"                              # 오리진 타입을 S3로 지정
  signing_behavior                  = "always"                          # 항상 서명하도록 설정
  signing_protocol                  = "sigv4"                           # AWS v4 서명 프로토콜 사용
}

# CloudFront 배포 구성
resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name              = var.bucket_domain_name                      # S3 버킷의 도메인 이름 지정
    origin_id                = "S3-${var.bucket_id}"                       # 오리진 식별자 설정
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id # 생성된 OAC ID 연결
  }

  enabled             = true               # CloudFront 배포 활성화
  default_root_object = var.index_document # 기본 루트 오브젝트 설정 (예: index.html)

  viewer_certificate {
    cloudfront_default_certificate = true # CloudFront 기본 인증서 사용
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]       # 허용된 HTTP 메서드
    cached_methods   = ["GET", "HEAD"]       # 캐시에 저장되는 HTTP 메서드
    target_origin_id = "S3-${var.bucket_id}" # 타겟 오리진 식별자 설정

    forwarded_values {
      query_string = false # 쿼리 스트링 전달 비활성화
      cookies {
        forward = "none" # 쿠키 전달 비활성화
      }
    }

    # viewer_protocol_policy = "allow-all"                                   # 모든 프로토콜 허용 (주석 처리됨)
    viewer_protocol_policy = "redirect-to-https" # HTTP 요청을 HTTPS로 리디렉션
  }

  restrictions {
    geo_restriction {
      restriction_type = "none" # 지역 제한 없음
    }
  }

  tags = {
    Name = "${var.bucket_name}-cloudfront" # CloudFront 배포의 태그 이름 설정
  }

  web_acl_id = aws_wafv2_web_acl.web_acl.arn # 생성된 WAF 웹 ACL을 CloudFront 배포에 연결
}

# CloudFront를 위한 S3 버킷 정책 생성
resource "aws_s3_bucket_policy" "static_site_policy" {
  bucket = var.bucket_id # 정책을 적용할 버킷 ID

  policy = jsonencode({
    Version = "2012-10-17",                        # 정책 버전
    Id      = "PolicyForCloudFrontPrivateContent", # 정책 식별자
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal", # 정책 설명 식별자
        Effect = "Allow",                           # 허용 정책
        Principal = {
          Service = "cloudfront.amazonaws.com" # CloudFront 서비스 프린시플
        },
        Action   = "s3:GetObject",        # S3 오브젝트 가져오기 권한
        Resource = "${var.bucket_arn}/*", # 버킷 내 모든 오브젝트에 대한 액세스
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = "${aws_cloudfront_distribution.s3_distribution.arn}" # 지정된 CloudFront 배포만 접근 가능하도록 조건 지정
          }
        }
      }
    ]
  })
}

# WAF Web ACL 생성
resource "aws_wafv2_web_acl" "web_acl" {
  name        = "${var.bucket_name}-web-acl"                       # WAF Web ACL 이름 설정
  description = "WAF for CloudFront to protect ${var.bucket_name}" # WAF 설명 추가
  scope       = "CLOUDFRONT"                                       # CloudFront용 WAF 스코프 지정

  default_action {
    allow {} # 기본적으로 모든 요청 허용
  }

  # 규칙 정의 (여기서는 Managed Rule Group 예시 사용)
  rule {
    name     = "AWS-CommonRules" # 규칙 이름 지정
    priority = 1                 # 규칙 우선순위

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet" # AWS 제공 관리형 규칙 그룹 사용
        vendor_name = "AWS"                          # 규칙 그룹 제공자
      }
    }

    # 규칙 동작 무시 설정 (기본 규칙 동작 수행)
    override_action {
      none {} # 규칙의 기본 동작 수행
    }

    # visibility_config을 통해 WAF가 어떻게 로그를 수집하고 메트릭을 기록할지 지정
    visibility_config {
      sampled_requests_enabled   = true                            # 샘플 요청 활성화
      cloudwatch_metrics_enabled = true                            # CloudWatch 메트릭 활성화
      metric_name                = "${var.bucket_name}-waf-metric" # CloudWatch 메트릭 이름
    }
  }

  # SQL 인젝션 규칙 설정
  rule {
    name     = "AWSManagedRulesSQLiRuleSet" # 규칙 이름 지정
    priority = 2                            # 규칙 우선순위

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet" # AWS 제공 SQL 인젝션 규칙 그룹 사용
        vendor_name = "AWS"                        # 규칙 그룹 제공자
      }
    }

    override_action {
      none {} # 규칙의 기본 동작 수행
    }

    visibility_config {
      sampled_requests_enabled   = true                            # 샘플 요청 활성화
      cloudwatch_metrics_enabled = true                            # CloudWatch 메트릭 활성화
      metric_name                = "${var.bucket_name}-waf-metric" # CloudWatch 메트릭 이름
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true                                # CloudWatch 메트릭 활성화
    metric_name                = "${var.bucket_name}-web-acl-metric" # Web ACL 메트릭 이름
    sampled_requests_enabled   = true                                # 샘플 요청 활성화
  }

  tags = {
    Name = "${var.bucket_name}-waf" # WAF Web ACL 태그 이름 설정
  }
}
