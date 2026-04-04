# S3 모듈 호출
module "s3" {
  source = "./modules/s3"

  bucket_name         = var.bucket_name
  environment         = var.environment
  index_document      = var.index_document
  error_document      = var.error_document
  index_document_path = var.index_document_path
  error_document_path = var.error_document_path
}

# CloudFront 모듈 호출
module "cloudfront" {
  source = "./modules/cloudfront"

  bucket_name        = var.bucket_name
  bucket_id          = module.s3.bucket_id
  bucket_domain_name = module.s3.bucket_domain_name
  index_document     = var.index_document
  error_document     = var.error_document
}

# S3 버킷 정책 — CloudFront OAC만 접근 허용
# CloudFront 모듈과 S3 모듈의 순환 의존성을 피하기 위해 root에서 관리
resource "aws_s3_bucket_policy" "static_site" {
  bucket = module.s3.bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${module.s3.bucket_arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = module.cloudfront.cloudfront_distribution_arn
          }
        }
      }
    ]
  })
}
