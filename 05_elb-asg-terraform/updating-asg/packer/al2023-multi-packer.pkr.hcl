# Packer 설정 블록
packer {
  # Packer에서 사용할 플러그인을 정의하는 부분
  required_plugins {
    amazon = {
      version = ">= 1.3.3" # Packer에서 사용할 플러그인의 최소 버전 지정
      source  = "github.com/hashicorp/amazon" # 플러그인 소스 위치 (AWS용 공식 HashiCorp 플러그인)
    }
  }
}

# AWS 리전을 정의하는 변수
variable "aws_region" {
  type    = string
  default = "us-east-1" # 기본 리전: us-east-1
}

# 인스턴스 타입을 정의하는 변수
variable "instance_type" {
  type    = string
  default = "t2.micro" # 기본 인스턴스 타입: t2.micro
}

# AWS CLI에서 사용할 프로파일을 정의하는 변수
variable "profile" {
  type    = string
  default = "my-profile" # 기본 프로파일: my-profile
}

# 사용할 AMI ID를 정의
data "amazon-ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filters = {
    name         = "al2023-ami-*"
    architecture = "x86_64"
  }
}

# 현재 시간에 기반하여 AMI 이름에 사용할 타임스탬프 생성
locals {
  timestamp = regex_replace(timestamp(), "[- TZ:]", "") # 현재 시간을 문자열로 가져온 후, 허용되지 않는 문자 제거
}

# 첫 번째 빌더: Old 버전의 nginx AMI 생성
source "amazon-ebs" "nginx_old" {
  profile       = var.profile       # AWS CLI 프로파일 지정
  region        = var.aws_region    # 리전 지정
  instance_type = var.instance_type # EC2 인스턴스 타입 지정
  ssh_username  = "ec2-user"        # EC2 인스턴스 SSH 접속용 사용자
  ami_name      = "packer-nginx-old-${local.timestamp}" # 생성할 AMI의 이름, 타임스탬프를 포함
  source_ami    = data.amazon-ami.al2023.id    # 소스로 사용할 AMI ID
}

# 두 번째 빌더: New 버전의 nginx AMI 생성
source "amazon-ebs" "nginx_new" {
  profile       = var.profile       # AWS CLI 프로파일 지정
  region        = var.aws_region    # 리전 지정
  instance_type = var.instance_type # EC2 인스턴스 타입 지정
  ssh_username  = "ec2-user"        # EC2 인스턴스 SSH 접속용 사용자
  ami_name      = "packer-nginx-new-${local.timestamp}" # 생성할 AMI의 이름, 타임스탬프를 포함
  source_ami    = data.amazon-ami.al2023.id    # 소스로 사용할 AMI ID
}

# Old 버전의 nginx 설치 및 index.html 파일 생성 빌드 블록
build {
  sources = ["source.amazon-ebs.nginx_old"]

  # 쉘 프로비저너를 통해 인스턴스에 nginx 설치 및 old index.html 파일 구성
  provisioner "shell" {
    inline = [
      "sudo yum update -y",                # 인스턴스 패키지 업데이트
      "sudo yum install nginx -y",         # NGINX 웹 서버 설치
      "echo '<h1>Old Version of index.html</h1>' | sudo tee /usr/share/nginx/html/index.html", # Old 버전의 index.html 생성
      "sudo systemctl enable nginx --now"  # NGINX 웹 서버 서비스 활성화 및 즉시 시작
    ]
  }
}

# New 버전의 nginx 설치 및 index.html 파일 생성 빌드 블록
build {
  sources = ["source.amazon-ebs.nginx_new"]

  # 쉘 프로비저너를 통해 인스턴스에 nginx 설치 및 new index.html 파일 구성
  provisioner "shell" {
    inline = [
      "sudo yum update -y",                # 인스턴스 패키지 업데이트
      "sudo yum install nginx -y",         # NGINX 웹 서버 설치
      "echo '<h1>New Version of index.html</h1>' | sudo tee /usr/share/nginx/html/index.html", # New 버전의 index.html 생성
      "sudo systemctl enable nginx --now"  # NGINX 웹 서버 서비스 활성화 및 즉시 시작
    ]
  }
}
