# main.tf 

#############################################################
# S3 설정
# 랜덤한 숫자 생성 (bucket 이름에 사용)
resource "random_integer" "bucket_suffix" {
  min = 1000 # 최소 값
  max = 9999 # 최대 값
}

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
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.static_site.id # 대상 버킷 지정
  key          = var.index_document           # 업로드할 오브젝트의 키 (파일명)
  source       = var.index_document_path      # 로컬에서 업로드할 인덱스 파일의 경로
  content_type = "text/html"                  # 파일의 MIME 타입 설정
}

# S3 버킷에 에러 파일 업로드
resource "aws_s3_object" "error" {
  bucket       = aws_s3_bucket.static_site.id # 대상 버킷 지정
  key          = var.error_document           # 업로드할 오브젝트의 키 (파일명)
  source       = var.error_document_path      # 로컬에서 업로드할 에러 파일의 경로
  content_type = "text/html"                  # 파일의 MIME 타입 설정
}

##################################################
# CloudFront 설정 
# CloudFront의 S3 접근을 위한 Origin Access Control 설정
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "S3-origin-access-control"        # OAC 이름 지정
  description                       = "OAC for CloudFront to S3 access" # 설명 추가
  origin_access_control_origin_type = "s3"                              # 오리진 타입을 S3로 지정
  signing_behavior                  = "always"                          # 항상 서명하도록 설정
  signing_protocol                  = "sigv4"                           # AWS v4 서명 프로토콜 사용
}

# CloudFront 배포 구성
resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name              = aws_s3_bucket.static_site.bucket_domain_name # S3 버킷의 정적 웹사이트 엔드포인트
    origin_id                = "S3-${aws_s3_bucket.static_site.id}"         # 오리진 식별자
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id  # OAC ID 연결
  }

  enabled             = true               # CloudFront 배포 활성화
  default_root_object = var.index_document # 기본 루트 오브젝트 지정 (예: index.html)

  # aliases를 제거하여 기본 CloudFront 도메인 사용
  # CloudFront에 도메인 이름(aliases)을 연결하려면 해당 도메인에 대한 유효한 SSL 인증서를 제공해야 하기 때문에 오류 발생
  # aliases = [var.domain_name] # 제거

  # ACM을 생성하기 까다로우므로 기본 CloudFront 인증서 사용
  viewer_certificate {
    cloudfront_default_certificate = true # CloudFront의 기본 인증서 사용
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]                      # 허용된 HTTP 메서드
    cached_methods   = ["GET", "HEAD"]                      # 캐시에 저장되는 HTTP 메서드
    target_origin_id = "S3-${aws_s3_bucket.static_site.id}" # 타겟 오리진 식별자 

    forwarded_values {
      query_string = false # 쿼리 스트링 전달 안 함
      cookies {
        forward = "none" # 쿠키 전달 안 함
      }
    }

    # viewer_protocol_policy = "allow-all" # HTTPS를 강제하지 않고 HTTP도 허용
    viewer_protocol_policy = "redirect-to-https" # HTTP 요청을 HTTPS로 리디렉션
  }

  restrictions {
    geo_restriction {
      restriction_type = "none" # 지역 제한 없음
    }
  }

  tags = {
    Name = "${var.bucket_name}-cloudfront" # 태그로 CloudFront 배포 이름 설정
  }
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
