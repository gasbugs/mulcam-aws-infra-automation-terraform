variable "private_dns_name" {
  description = "Private DNS 도메인 이름"
  type        = string
}

variable "instance_type" {
  description = "EC2 인스턴스 타입"
  type        = string
}

variable "cloudfront_domain_name" {
  description = "Route53 alias 레코드가 가리킬 CloudFront 배포의 도메인 이름"
  type        = string
}

variable "cloudfront_hosted_zone_id" {
  description = "Route53 alias 레코드 설정에 필요한 CloudFront 배포의 hosted zone ID"
  type        = string
}
