# CloudFront 배포 수정
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "S3-origin-access-control"        # OAC 이름 지정
  description                       = "OAC for CloudFront to S3 access" # 설명 추가
  origin_access_control_origin_type = "s3"                              # 오리진 타입을 S3로 지정
  signing_behavior                  = "always"                          # 항상 서명하도록 설정
  signing_protocol                  = "sigv4"                           # AWS v4 서명 프로토콜 사용
}

resource "aws_cloudfront_distribution" "s3_distribution" {
  # 기존 S3 오리진
  origin {
    domain_name              = aws_s3_bucket.static_site.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.static_site.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
    # origin_path              = "/static" # 추가
  }

  # CLB 오리진 추가
  origin {
    domain_name = data.kubernetes_service.netflux_svc.status.0.load_balancer.0.ingress.0.hostname
    origin_id   = "EKS-CLB"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled = true
  #default_root_object = var.index_document


  # ACM을 생성하기 까다로우므로 기본 CloudFront 인증서 사용
  viewer_certificate {
    cloudfront_default_certificate = true # CloudFront의 기본 인증서 사용
  }

  # 기본 캐시 동작 (CLB로 라우팅)
  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "EKS-CLB"

    forwarded_values {
      query_string = true
      cookies {
        forward = "all"
      }
    }
    viewer_protocol_policy = "allow-all"
  }

  # /static/* 경로에 대한 캐시 동작 (S3로 라우팅)
  ordered_cache_behavior {
    path_pattern     = "*.jpg"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = "S3-${aws_s3_bucket.static_site.id}"

    forwarded_values {
      query_string = false
      headers      = ["Origin"]
      cookies {
        forward = "none"
      }
    }
    viewer_protocol_policy = "redirect-to-https"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = "${var.bucket_name}-cloudfront"
  }
}


#############################################################
# S3 설정

# S3 버킷 생성
resource "aws_s3_bucket" "static_site" {
  bucket = "${var.bucket_name}-${random_integer.bucket_suffix.result}" # 버킷 이름에 랜덤 숫자 추가

  tags = {
    Name        = var.bucket_name # 태그로 버킷 이름 설정
    Environment = var.environment # 환경에 대한 태그 지정 (예: dev, prod)
  }
}

# S3 버킷의 정적 웹사이트 설정 구성
resource "aws_s3_bucket_website_configuration" "static_site_website" {
  bucket = aws_s3_bucket.static_site.id # 대상 버킷 지정

  index_document {
    suffix = var.index_document # 인덱스 문서 설정 (예: index.html)
  }

  error_document {
    key = var.error_document # 에러 문서 설정 (예: error.html)
  }
}

# S3 버킷에 인덱스 파일 업로드
resource "aws_s3_object" "static_files" {
  for_each = fileset("./static/", "**/*")
  bucket   = aws_s3_bucket.static_site.id
  key      = each.value
  source   = "./static/${each.value}"
  etag     = filemd5("./static/${each.value}")
}


# CloudFront를 위한 S3 버킷 정책 생성 
resource "aws_s3_bucket_policy" "static_site_policy" {
  bucket = aws_s3_bucket.static_site.id # 정책을 적용할 버킷

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
        Action   = "s3:GetObject",                       # S3 오브젝트 가져오기 권한
        Resource = "${aws_s3_bucket.static_site.arn}/*", # 버킷 내 모든 오브젝트에 대한 액세스
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = "${aws_cloudfront_distribution.s3_distribution.arn}" # 지정된 CloudFront 배포만 접근 가능하도록 조건 지정
          }
        }
      }
    ]
  })
}
