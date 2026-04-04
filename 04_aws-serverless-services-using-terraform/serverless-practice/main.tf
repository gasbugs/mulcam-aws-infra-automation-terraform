# 버킷 이름 충돌 방지를 위한 랜덤 숫자 접미사 생성
resource "random_integer" "bucket_suffix" {
  min = 1000
  max = 9999
}

# 공식 S3 모듈로 버킷 생성 및 퍼블릭 액세스 차단 설정
# 출처: terraform-aws-modules/s3-bucket/aws (Terraform 공식 레지스트리)
module "s3" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 5.0"

  # 버킷 이름 = 기본 이름 + 랜덤 숫자 (전역 유일성 보장)
  bucket = "${var.bucket_name}-${random_integer.bucket_suffix.result}"

  # CloudFront OAC 방식 사용 시 S3 퍼블릭 액세스를 모두 차단해야 함
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  tags = {
    Name        = var.bucket_name
    Environment = var.environment
  }
}

# 인덱스 HTML 파일을 S3 버킷에 업로드
# 공식 모듈은 파일 업로드를 지원하지 않으므로 루트에서 직접 관리
resource "aws_s3_object" "index" {
  bucket       = module.s3.s3_bucket_id
  key          = var.index_document
  source       = var.index_document_path
  content_type = "text/html"
  etag         = filemd5(var.index_document_path)
}

# 에러 HTML 파일을 S3 버킷에 업로드
resource "aws_s3_object" "error" {
  bucket       = module.s3.s3_bucket_id
  key          = var.error_document
  source       = var.error_document_path
  content_type = "text/html"
  etag         = filemd5(var.error_document_path)
}

# CloudFront 모듈 호출 — S3 공식 모듈 출력값으로 연결
module "cloudfront" {
  source = "./modules/cloudfront"

  bucket_name        = var.bucket_name
  bucket_id          = module.s3.s3_bucket_id                           # 공식 모듈 출력: 버킷 이름
  bucket_domain_name = module.s3.s3_bucket_bucket_regional_domain_name  # 공식 모듈 출력: 리전 도메인
  index_document     = var.index_document
  error_document     = var.error_document
}

# S3 버킷 정책 — CloudFront OAC(Origin Access Control)만 S3에 접근 허용
# 순환 의존성 방지를 위해 cloudfront/s3 모듈 밖의 루트에서 관리
resource "aws_s3_bucket_policy" "static_site" {
  bucket = module.s3.s3_bucket_id

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
        Resource = "${module.s3.s3_bucket_arn}/*"  # 공식 모듈 출력: 버킷 ARN
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = module.cloudfront.cloudfront_distribution_arn
          }
        }
      }
    ]
  })
}

# route53_with_ec2 모듈 호출 — CloudFront 도메인을 Route53에 등록
module "route53_with_ec2" {
  source = "./modules/route53_with_ec2"

  cloudfront_domain_name    = module.cloudfront.cloudfront_domain_name
  cloudfront_hosted_zone_id = module.cloudfront.cloudfront_hosted_zone_id

  private_dns_name = var.private_dns_name
  instance_type    = var.instance_type
}
