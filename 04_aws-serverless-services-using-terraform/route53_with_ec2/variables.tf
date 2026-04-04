variable "aws_region" {
  description = "AWS 리전"
  type        = string
}

variable "aws_profile" {
  description = "AWS Profile"
  type        = string
}

variable "private_dns_name" {
  description = "Private DNS 도메인 이름"
  type        = string
}

variable "test_record_ip_1" {
  description = "Private DNS 레코드가 가리킬 IP 주소"
  type        = string
}

variable "test_record_ip_2" {
  description = "Private DNS 레코드가 가리킬 IP 주소"
  type        = string
}

variable "instance_type" {
  description = "EC2 인스턴스 타입"
  type        = string
}



