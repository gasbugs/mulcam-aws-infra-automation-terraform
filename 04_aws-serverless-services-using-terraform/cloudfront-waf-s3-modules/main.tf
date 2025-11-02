# main.tf

# 모듈 호출
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
  bucket_arn         = module.s3.bucket_arn
  index_document     = var.index_document
}
