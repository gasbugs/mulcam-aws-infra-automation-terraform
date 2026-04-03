##########################################################################
# 공통 로컬 설정
##########################################################################
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  ec2_instances = {
    "1" = { az_index = 0 }
    "2" = { az_index = 1 }
    "3" = { az_index = 2 }
  }
}

##########################################################################
# EC2 설정
##########################################################################
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical 공식 AWS 계정 ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "tls_private_key" "my_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "random_string" "key_name_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "aws_key_pair" "my_key_pair" {
  key_name   = "my-key-${random_string.key_name_suffix.result}"
  public_key = tls_private_key.my_key.public_key_openssh

  tags = {
    Name        = "my-key-${random_string.key_name_suffix.result}"
    Environment = var.environment
  }
}

# 생성된 개인 키를 로컬 파일로 저장 (state에 평문 저장되므로 원격 백엔드 + 암호화 권장)
resource "local_file" "private_key" {
  content         = tls_private_key.my_key.private_key_pem
  filename        = "${path.module}/my-key.pem"
  file_permission = "0600"
}

resource "aws_instance" "my_ec2" {
  for_each = local.ec2_instances

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.my_key_pair.key_name
  subnet_id                   = module.my_vpc.public_subnets[each.value.az_index]
  vpc_security_group_ids      = [aws_security_group.my_sg.id]
  associate_public_ip_address = true

  tags = {
    Name        = "MyFirstInstance-${each.key}"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

##########################################################################
# VPC 설정
##########################################################################
module "my_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name = "my-vpc-${var.environment}"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway   = false
  single_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform   = "true"
    Environment = var.environment
  }
}

resource "aws_security_group" "my_sg" {
  name        = "my-sg-${var.environment}"
  description = "Security group for EC2 instances - allow SSH"
  vpc_id      = module.my_vpc.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "my-sg-${var.environment}"
    Environment = var.environment
  }
}
