# AWS가 공식으로 제공하는 "캐싱 최적화" 정책을 이름으로 검색해서 가져옵니다.
# 숫자로 된 ID를 직접 쓰는 것보다 이름을 사용하면 나중에 읽는 사람도 어떤 정책인지 바로 알 수 있습니다.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# CloudFront의 S3 접근을 위한 Origin Access Control 설정
# OAC(Origin Access Control): CloudFront만 S3 버킷에 접근할 수 있도록 하는 보안 장치입니다.
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${var.bucket_name}-oac"
  description                       = "OAC for CloudFront to S3 access"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront 배포 구성
# CloudFront: 전 세계 여러 곳에 배치된 AWS 서버를 통해 웹사이트를 빠르게 전달하는 서비스입니다.
resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name              = var.bucket_domain_name
    origin_id                = "S3-${var.bucket_id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  enabled             = true
  default_root_object = var.index_document

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${var.bucket_id}"

    # data source로 가져온 캐시 정책 ID를 사용합니다. (하드코딩 제거)
    cache_policy_id = data.aws_cloudfront_cache_policy.caching_optimized.id

    viewer_protocol_policy = "redirect-to-https"

    # compress: 파일을 압축해서 전송하면 데이터 용량이 줄어들어 웹사이트가 더 빠르게 열립니다.
    compress = true
  }

  # 존재하지 않는 페이지를 요청했을 때의 오류 처리 설정입니다.
  # S3 버킷이 비공개이므로, 없는 파일을 요청하면 S3가 403(접근 거부)을 반환합니다.
  # 방문자에게 403 오류 대신 우리가 만든 에러 페이지(error.html)를 보여주도록 설정합니다.
  custom_error_response {
    # S3에서 403(접근 거부) 오류가 오면
    error_code = 403
    # 방문자에게는 404(페이지 없음)로 표시하고
    response_code = 404
    # 이 에러 페이지를 보여줍니다
    response_page_path = "/${var.error_document}"
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
