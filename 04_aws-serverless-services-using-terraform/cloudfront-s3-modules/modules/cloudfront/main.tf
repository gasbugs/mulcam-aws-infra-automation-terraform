# CloudFront의 S3 접근을 위한 Origin Access Control 설정
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "S3-origin-access-control"
  description                       = "OAC for CloudFront to S3 access"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront 배포 구성
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

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
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

# CloudFront를 위한 S3 버킷 정책 생성 
resource "aws_s3_bucket_policy" "static_site_policy" {
  bucket = var.bucket_id

  policy = jsonencode({
    Version = "2012-10-17",
    Id      = "PolicyForCloudFrontPrivateContent",
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal",
        Effect = "Allow",
        Principal = {
          Service = "cloudfront.amazonaws.com"
        },
        Action   = "s3:GetObject",
        Resource = "${var.bucket_arn}/*",
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = "${aws_cloudfront_distribution.s3_distribution.arn}"
          }
        }
      }
    ]
  })
}
