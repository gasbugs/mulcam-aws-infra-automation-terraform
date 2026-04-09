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
    # 키페어 생성을 위해 공개키/개인키 생성을 위한 tls 프로바이더를 사용
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # 내 로컬에 키페어 파일을 저장하기 위한 local 프로바이더를 사용
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

# 현재 계정에서 사용 가능한 zone을 검색하는 기능
data "aws_availability_zones" "available" {}

# VPC 생성
resource "aws_vpc" "my_vpc" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_hostnames = true # DNS 기능 활성화

  tags = {
    Name = "MyVPC" # AWS에서는 원래 Name 기능이 없었다. 
    # 지금은 태그에 Name을 넣으면 콘솔에서 표기함.  
    Environment = var.environment
  }
}

# 서브넷 생성
resource "aws_subnet" "public_subnet" {
  vpc_id            = aws_vpc.my_vpc.id     # 의존성을 명시해야 순서가 보장됨
  cidr_block        = var.subnet_cidr_block # 10.0.1.0/24
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name        = "PublicSubnet"
    Environment = var.environment
  }
}

# IGW 생성
resource "aws_internet_gateway" "my_igw" {
  vpc_id = aws_vpc.my_vpc.id

  tags = {
    Name        = "MyInternetGateway"
    Environment = var.environment
  }
}

# 라우트 테이블 생성
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

# 라우트 테이블과 서브넷 연결
resource "aws_route_table_association" "public_subnet_association" {
  route_table_id = aws_route_table.public_route_table.id # 어떤 라우트 테이블을
  subnet_id      = aws_subnet.public_subnet.id           # 어떤 서브넷에 
}

# ec2 SW 방화벽 구성 
resource "aws_security_group" "my_sg" {
  vpc_id = aws_vpc.my_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
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

# AL2023 최신 버전 사용 
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

# EC2 생성
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

# 키페어 이름은 내 계정에서 고유해야 함
resource "random_string" "key_name_suffix" {
  length  = 8
  special = false # 특수 문자 사용 여부
  upper   = false # 대문자 사용 여부
}

# RSA 4096비트 키를 생성 
resource "tls_private_key" "my_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# 로컬에서 프라이빗 키를 저장 
resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.my_key.private_key_pem
  filename        = "${path.module}/my-key.pem"
  file_permission = "0600"
}

# 새로 생성된 키를 AWS 키페어에 등록 (퍼블릭키만 등록)
resource "aws_key_pair" "my_key_pair" {
  key_name   = "my-key-${random_string.key_name_suffix.result}"
  public_key = tls_private_key.my_key.public_key_openssh
}
