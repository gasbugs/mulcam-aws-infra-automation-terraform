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
  bucket_arn         = module.s3.bucket_arn
  index_document     = var.index_document
}

# route53_with_ec2 모듈 호출
module "route53_with_ec2" {
  source = "./modules/route53_with_ec2"

  cloudfront_domain_name    = module.cloudfront.cloudfront_domain_name
  cloudfront_hosted_zone_id = module.cloudfront.cloudfront_hosted_zone_id

  private_dns_name  = var.private_dns_name
  ami_id            = data.aws_ami.al2023.id
  instance_type     = var.instance_type
  pub_key_file_path = var.pub_key_file_path
}


# Amazon Linux 2023 AMI ID를 검색하는 데이터 소스 설정
data "aws_ami" "al2023" {
  most_recent = true       # 최신 AMI를 가져오도록 설정
  owners      = ["amazon"] # AMI 소유자가 Amazon인 것만 필터링

  filter {
    name   = "name"           # 필터 조건: 이름이 특정 패턴과 일치해야 함
    values = ["al2023-ami-*"] # Amazon Linux 2023 AMI 이름 패턴과 일치하는 값만 가져옴
  }

  filter {
    name   = "architecture" # 필터 조건: 아키텍처가 특정 값과 일치해야 함
    values = ["x86_64"]     # x86_64 아키텍처 AMI만 가져옴
  }
}
