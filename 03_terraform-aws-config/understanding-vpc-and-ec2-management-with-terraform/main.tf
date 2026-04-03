terraform {
  required_version = ">=1.13.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

data "aws_availability_zones" "available" {}

resource "aws_vpc" "my_vpc" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_hostnames = true

  tags = {
    Name        = "MyVPC"
    Environment = var.environment
  }
}

resource "aws_subnet" "public_subnet" {
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = var.subnet_cidr_block
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name        = "PublicSubnet"
    Environment = var.environment
  }
}

resource "aws_internet_gateway" "my_igw" {
  vpc_id = aws_vpc.my_vpc.id

  tags = {
    Name        = "MyInternetGateway"
    Environment = var.environment
  }
}

resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.my_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.my_igw.id
  }

  tags = {
    Name        = "PublicRouteTable"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "public_subnet_association" {
  route_table_id = aws_route_table.public_route_table.id
  subnet_id      = aws_subnet.public_subnet.id
}

resource "aws_security_group" "my_sg" {
  vpc_id = aws_vpc.my_vpc.id

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
    Name        = "MySecurityGroup"
    Environment = var.environment
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_instance" "my_ec2" {
  ami                         = data.aws_ami.al2023.id            # 사용할 AMI ID 설정
  instance_type               = var.instance_type                 # EC2 인스턴스 유형
  subnet_id                   = aws_subnet.public_subnet.id       # 퍼블릭 서브넷에 인스턴스 배치
  vpc_security_group_ids      = [aws_security_group.my_sg.id]     # 적용할 보안 그룹 ID
  associate_public_ip_address = var.associate_public_ip           # 퍼블릭 IP 할당 여부
  key_name                    = aws_key_pair.my_key_pair.key_name # 생성한 Key Pair 지정

  # 루트 볼륨 설정
  root_block_device {
    volume_size           = 30    # 루트 볼륨 크기 (GB)
    volume_type           = "gp3" # 볼륨 타입 (gp2, gp3, io1 등)
    delete_on_termination = true  # 인스턴스 종료 시 볼륨 삭제 여부
    encrypted             = true  # 암호화 여부
  }

  tags = {
    Name        = "MyEC2Instance" # 인스턴스에 "MyEC2Instance"라는 이름 태그 추가
    Environment = var.environment
  }
}

# 추가 디스크 설정 
resource "aws_ebs_volume" "example_volume" {
  availability_zone = aws_instance.my_ec2.availability_zone # EC2 인스턴스와 동일한 AZ
  size              = 10                                    # 볼륨 크기 (GB)
  type              = "gp3"                                 # 볼륨 타입 (예: gp3, io1 등)
  encrypted         = true                                  # 암호화 여부
  tags = {
    Name        = "ExampleVolume"
    Environment = var.environment
  }
}

# 추가 디스크 연결 
resource "aws_volume_attachment" "example_attachment" {
  device_name = "/dev/xvdf"                      # EC2에 마운트될 디바이스 이름
  volume_id   = aws_ebs_volume.example_volume.id # 연결할 EBS 볼륨 ID
  instance_id = aws_instance.my_ec2.id           # 연결할 EC2 인스턴스 ID
}

resource "random_string" "key_name_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "tls_private_key" "my_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.my_key.private_key_pem
  filename        = "${path.module}/my-key.pem"
  file_permission = "0600"
}

resource "aws_key_pair" "my_key_pair" {
  key_name   = "my-key-${random_string.key_name_suffix.result}"
  public_key = tls_private_key.my_key.public_key_openssh
}
