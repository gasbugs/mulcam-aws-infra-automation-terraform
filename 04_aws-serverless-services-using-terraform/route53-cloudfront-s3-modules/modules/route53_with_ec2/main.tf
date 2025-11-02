##########################################################################
# VPC 설정
##########################################################################
locals {
  aws_zone_mapping = {
    "us-east-1" = ["a", "b", "c"]
  }
  azs = [for az in local.aws_zone_mapping[var.aws_region] : "${var.aws_region}${az}"]
}

module "my_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name = "my-vpc"
  cidr = "10.0.0.0/16"

  azs             = local.azs
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = false
  single_nat_gateway = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

##########################################################################
# EC2 설정
##########################################################################
# 랜덤한 숫자 생성 (키 페어 이름에 사용)
resource "random_integer" "key_suffix" {
  min = 1000 # 최소 값
  max = 9999 # 최대 값
}

# 키 페어 생성
resource "aws_key_pair" "generated_key_pair" {
  key_name   = "my-key-${random_integer.key_suffix.result}" # 랜덤한 숫자를 포함한 키 페어 이름
  public_key = file(pathexpand(var.pub_key_file_path))      # 공개 키 파일의 경로 지정 (로컬에 저장된 .pub 파일)
}

# 보안 그룹 생성 (SSH와 DNS 쿼리를 허용)
resource "aws_security_group" "ec2_sg" {
  name        = "ec2-sg"                    # 보안 그룹의 이름
  description = "Allow SSH and DNS traffic" # 보안 그룹에 대한 설명
  vpc_id      = module.my_vpc.vpc_id        # 보안 그룹이 속할 VPC ID

  ingress {
    description = "Allow SSH" # SSH 트래픽 허용
    from_port   = 22          # SSH 포트
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # 모든 IP 대역에서의 SSH 트래픽 허용
  }

  ingress {
    description = "Allow DNS" # DNS 쿼리 허용
    from_port   = 53          # DNS 포트
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"] # 모든 IP 대역에서의 DNS 트래픽 허용
  }

  egress {
    from_port   = 0 # 아웃바운드 트래픽 허용 (모든 포트 및 프로토콜)
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # 모든 IP 대역에 대한 아웃바운드 허용
  }
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

# EC2 인스턴스 생성 (Private DNS 테스트용)
resource "aws_instance" "dns_test_instance" {
  ami                         = data.aws_ami.al2023.id                   # EC2 인스턴스에 사용할 AMI ID
  instance_type               = var.instance_type                        # EC2 인스턴스의 유형
  subnet_id                   = module.my_vpc.public_subnets[0]          # EC2 인스턴스를 생성할 서브넷 ID
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]           # EC2 인스턴스에 적용할 보안 그룹
  key_name                    = aws_key_pair.generated_key_pair.key_name # 생성한 키 페어 이름 사용
  associate_public_ip_address = true

  tags = {
    Name = "PrivateDNS-Test-Instance" # 인스턴스의 태그 이름 설정
  }
}

##########################################################################
# Route53 설정
##########################################################################
# Route 53 Private Hosted Zone 생성 (VPC와 연결된 Private DNS 영역)
resource "aws_route53_zone" "private_dns" {
  name = var.private_dns_name # Private Hosted Zone의 도메인 이름
  vpc {
    vpc_id = module.my_vpc.vpc_id # Private Hosted Zone을 연결할 VPC ID
  }
  comment = "Private DNS zone for ${var.private_dns_name}" # Hosted Zone에 대한 설명
}

# CloudFront 도메인 이름을 가리키는 A 레코드 생성
resource "aws_route53_record" "alias_record" {
  zone_id = aws_route53_zone.private_dns.zone_id # Route 53 Zone ID
  name    = var.private_dns_name                 # 도메인 이름
  type    = "A"                                  # A 레코드 타입 지정

  alias {
    name                   = var.cloudfront_domain_name    # CloudFront 도메인 이름 지정
    zone_id                = var.cloudfront_hosted_zone_id # CloudFront의 호스팅 Zone ID
    evaluate_target_health = false                         # 타겟의 상태를 평가하지 않음
  }

  # 가중치 라우팅을 위해 고유 식별자 설정
  set_identifier = "cloudfront-record-1"

  weighted_routing_policy {
    weight = 100 # 100%의 트래픽을 이 배포로 라우팅 (레코드를 여러개 구성해서 가중치 분산 가능)
  }
}
