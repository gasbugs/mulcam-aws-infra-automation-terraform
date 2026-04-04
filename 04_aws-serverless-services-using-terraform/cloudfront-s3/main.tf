# main.tf
# CloudFront + S3 정적 웹사이트 호스팅 인프라를 정의합니다.
#
# [전체 구조]
#   사용자 브라우저 → CloudFront(CDN) → S3 버킷(HTML 파일 저장)
#
# CloudFront는 전 세계 엣지 서버에 콘텐츠를 캐싱해 빠르게 제공합니다.
# S3는 HTML/CSS/JS 파일을 저장하는 저장소 역할을 합니다.
# OAC(Origin Access Control)를 통해 S3를 외부에서 직접 접근하지 못하도록 막고,
# 오직 CloudFront를 통해서만 접근할 수 있도록 보안을 설정합니다.

#############################################################
# 1. 랜덤 숫자 생성
#############################################################

# S3 버킷 이름은 전 세계에서 유일해야 합니다.
# 같은 이름이 이미 존재하면 생성에 실패하므로, 뒤에 랜덤 숫자를 붙여 고유성을 확보합니다.
resource "random_integer" "bucket_suffix" {
  min = 1000 # 최솟값: 4자리 숫자로 만들기 위해 1000부터 시작
  max = 9999 # 최댓값
}

#############################################################
# 2. S3 버킷 생성
#############################################################

# HTML, CSS, 이미지 등 웹사이트 파일을 저장할 S3 버킷을 생성합니다.
# S3(Simple Storage Service)는 AWS의 파일 저장 서비스입니다.
resource "aws_s3_bucket" "static_site" {
  bucket = "${var.bucket_name}-${random_integer.bucket_suffix.result}" # 이름 뒤에 랜덤 숫자 추가

  tags = {
    Name        = var.bucket_name  # 리소스를 쉽게 찾을 수 있도록 붙이는 이름표
    Environment = var.environment  # 개발/운영 등 환경을 구분하는 태그
  }
}

#############################################################
# 3. S3 퍼블릭 액세스 완전 차단 (보안 강화)
#############################################################

# [추가] S3 버킷에 인터넷에서 직접 접근하는 것을 완전히 차단합니다.
# OAC를 사용하면 CloudFront만 S3에 접근하면 되므로, 버킷을 외부에 공개할 필요가 없습니다.
# 실수로 파일을 공개(Public)로 설정하더라도 이 설정이 막아주는 보안 안전장치입니다.
resource "aws_s3_bucket_public_access_block" "static_site" {
  bucket = aws_s3_bucket.static_site.id

  block_public_acls       = true # ACL(접근 제어 목록)을 통한 공개 설정을 차단
  block_public_policy     = true # 버킷 정책을 통한 공개 설정을 차단
  ignore_public_acls      = true # 이미 설정된 공개 ACL도 무시
  restrict_public_buckets = true # 퍼블릭 버킷으로 동작하는 것을 완전히 제한
}

#############################################################
# 4. S3에 웹사이트 파일 업로드
#############################################################

# 로컬(내 컴퓨터)에 있는 index.html 파일을 S3에 업로드합니다.
# etag는 파일의 "지문(체크섬)"으로, 파일 내용이 바뀌면 Terraform이 자동으로 감지해 다시 업로드합니다.
# [수정] etag 추가: 이전에는 파일 내용을 변경해도 Terraform이 변경 사항을 인식하지 못했습니다.
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.static_site.id
  key          = var.index_document                        # S3에 저장될 파일 이름
  source       = "${var.www_dir}/${var.index_document}"    # www/ 디렉토리 안의 파일을 참조
  content_type = "text/html"                               # 파일 형식을 브라우저에 알려주는 MIME 타입
  etag         = filemd5("${var.www_dir}/${var.index_document}") # 파일 내용 변경 감지용 해시값
}

# 로컬에 있는 error.html 파일을 S3에 업로드합니다.
# 404 오류 등 잘못된 경로 접근 시 이 파일이 표시됩니다.
resource "aws_s3_object" "error" {
  bucket       = aws_s3_bucket.static_site.id
  key          = var.error_document
  source       = "${var.www_dir}/${var.error_document}"
  content_type = "text/html"
  etag         = filemd5("${var.www_dir}/${var.error_document}") # 파일 내용 변경 감지용 해시값
}

#############################################################
# 5. CloudFront OAC(Origin Access Control) 설정
#############################################################

# OAC는 "CloudFront가 S3에 접근할 때 사용하는 신분증" 같은 개념입니다.
# S3는 이 신분증을 가진 CloudFront 요청만 허용하고, 일반 인터넷 접근은 거부합니다.
# 과거에는 OAI(Origin Access Identity)를 사용했지만, OAC가 더 안전한 최신 방식입니다.
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "S3-origin-access-control"
  description                       = "CloudFront가 S3 버킷에 안전하게 접근하기 위한 OAC 설정"
  origin_access_control_origin_type = "s3"      # 오리진(원본 서버) 타입을 S3로 지정
  signing_behavior                  = "always"  # 모든 요청에 항상 서명(인증)을 붙임
  signing_protocol                  = "sigv4"   # AWS 표준 서명 방식(Signature Version 4) 사용
}

#############################################################
# 6. CloudFront 배포(Distribution) 생성
#############################################################

# CloudFront는 AWS의 CDN(Content Delivery Network) 서비스입니다.
# 전 세계 엣지 서버에 콘텐츠를 캐싱하여 사용자에게 빠르게 전달합니다.
# 예: 서울 사용자가 접속하면 미국 S3 대신 서울 엣지 서버의 캐시에서 응답합니다.
resource "aws_cloudfront_distribution" "s3_distribution" {

  # 오리진(Origin): CloudFront가 콘텐츠를 가져올 원본 서버 설정
  origin {
    # [수정] bucket_domain_name → bucket_regional_domain_name
    # OAC를 사용할 때는 반드시 "리전별 도메인"을 사용해야 합니다.
    # 글로벌 도메인(bucket_domain_name)은 OAC 인증 요청을 올바르게 처리하지 못해 오류가 발생할 수 있습니다.
    domain_name              = aws_s3_bucket.static_site.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.static_site.id}" # 이 배포 내에서 오리진을 구별하는 고유 ID
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id # 위에서 만든 OAC 연결
  }

  enabled             = true               # CloudFront 배포를 활성화
  default_root_object = var.index_document # 루트 URL(/) 접속 시 반환할 기본 파일

  # HTTPS 인증서 설정
  # 커스텀 도메인을 사용하지 않으므로 CloudFront에서 기본 제공하는 인증서를 사용합니다.
  # (커스텀 도메인을 쓰려면 ACM에서 SSL 인증서를 별도로 발급받아야 합니다.)
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  # 기본 캐시 동작 설정: 사용자 요청을 어떻게 처리할지 정의합니다.
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]                       # 허용할 HTTP 메서드 (정적 사이트는 읽기만 필요)
    cached_methods   = ["GET", "HEAD"]                       # 실제로 캐시에 저장할 메서드
    target_origin_id = "S3-${aws_s3_bucket.static_site.id}" # 요청을 보낼 오리진 지정

    # [수정] forwarded_values → cache_policy_id (권장 방식)
    # forwarded_values 블록은 오래된 방식으로 현재는 사용을 권장하지 않습니다(deprecated).
    # AWS가 미리 만들어 둔 "CachingOptimized" 관리형 캐시 정책을 사용합니다.
    # 이 정책은 쿼리 스트링/쿠키를 전달하지 않고 응답을 최대한 캐싱하도록 최적화되어 있습니다.
    # ID "658327ea-f89d-4fab-a63d-7e88639e58f6"는 AWS가 제공하는 CachingOptimized 정책의 고정 ID입니다.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    # HTTP로 접속하면 자동으로 HTTPS로 전환시킵니다.
    # 보안을 위해 암호화된 HTTPS 연결을 강제합니다.
    viewer_protocol_policy = "redirect-to-https"
  }

  # 지역 제한 설정: 특정 국가에서의 접근을 차단할 수 있습니다.
  # "none"으로 설정하면 전 세계 어디서나 접근 가능합니다.
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name        = "${var.bucket_name}-cloudfront"
    Environment = var.environment # [추가] S3 버킷과 동일한 환경 태그를 추가해 일관성을 맞춥니다.
  }
}

#############################################################
# 7. S3 버킷 정책: CloudFront만 접근 허용
#############################################################

# S3 버킷 정책은 "누가 이 버킷에 접근할 수 있는가"를 정의하는 규칙입니다.
# 이 정책은 위에서 만든 CloudFront 배포에서 오는 요청만 허용하고, 나머지는 모두 거부합니다.
resource "aws_s3_bucket_policy" "static_site_policy" {
  bucket = aws_s3_bucket.static_site.id

  # jsonencode()는 Terraform의 데이터 구조를 JSON 형식의 텍스트로 변환해줍니다.
  policy = jsonencode({
    Version = "2012-10-17"                         # AWS 정책 언어의 버전 (항상 이 값을 사용)
    Id      = "PolicyForCloudFrontPrivateContent"  # 이 정책을 구별하는 식별자
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal" # 이 규칙(Statement)의 이름
        Effect = "Allow"                           # 접근을 "허용"

        # Principal: 이 정책을 적용받는 대상
        # CloudFront 서비스 자체가 S3에 접근하도록 허용합니다.
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }

        Action   = "s3:GetObject"                       # 허용하는 작업: S3 파일 읽기만 가능
        Resource = "${aws_s3_bucket.static_site.arn}/*" # 이 버킷 안의 모든 파일에 적용

        # Condition(조건): 위 허용이 적용되려면 반드시 이 조건을 충족해야 합니다.
        # 지정된 CloudFront 배포에서 온 요청만 허용합니다.
        # 다른 CloudFront 배포가 이 버킷에 무단 접근하는 것을 방지합니다.
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.s3_distribution.arn
          }
        }
      }
    ]
  })
}
