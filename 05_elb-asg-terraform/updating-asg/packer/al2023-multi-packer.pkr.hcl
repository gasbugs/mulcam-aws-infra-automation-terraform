# Packer 설정 블록
packer {
  # Packer에서 사용할 플러그인을 정의하는 부분
  required_plugins {
    amazon = {
      # ~> 1.6 은 1.6.x 버전만 허용 (메이저 버전 고정) — >= 보다 예측 가능한 빌드 보장
      version = "~> 1.6"
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
  default = "t3.micro" # 기본 인스턴스 타입: t3.micro
}

# AWS CLI에서 사용할 프로파일을 정의하는 변수
variable "profile" {
  type    = string
  default = "my-profile" # 기본 프로파일: my-profile
}

# 베이스 AMI를 동적으로 조회 — 하드코딩 없이 항상 최신 Amazon Linux 2023 공식 AMI를 사용
data "amazon-ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filters = {
    name                = "al2023-ami-*-x86_64"      # Amazon Linux 2023 공식 이름 패턴
    root-device-type    = "ebs"                       # EBS 루트 디바이스 (스냅샷 기반 AMI)
    virtualization-type = "hvm"                       # HVM 가상화 (현재 표준 방식)
  }
}

# 현재 시간에 기반하여 AMI 이름에 사용할 타임스탬프 생성
locals {
  timestamp = regex_replace(timestamp(), "[- TZ:]", "") # 현재 시간을 문자열로 가져온 후, 허용되지 않는 문자 제거
}

# Amazon EBS 기반 AMI 빌더 소스 정의 — 임시 EC2를 띄워 소프트웨어를 설치한 뒤 AMI로 굽는 방식
source "amazon-ebs" "al2023_httpd" {
  profile       = var.profile       # AWS CLI 프로파일 지정
  region        = var.aws_region    # 리전 지정
  instance_type = var.instance_type # 빌드에 사용할 임시 EC2 인스턴스 타입
  ssh_username  = "ec2-user"        # Amazon Linux 기본 SSH 사용자
  source_ami    = data.amazon-ami.al2023.id             # 위에서 조회한 최신 AL2023 AMI 사용
  ami_name      = "packer-amazon-linux-2023-${local.timestamp}" # 타임스탬프로 이름 중복 방지
  ami_description = "Amazon Linux 2023 with Apache httpd — built by Packer" # AMI 설명 (콘솔에서 식별 용이)

  # 생성된 AMI에 태그 추가 — AWS 콘솔에서 용도·빌드 날짜를 쉽게 식별하기 위함
  tags = {
    Name      = "packer-amazon-linux-2023-httpd"
    BuildDate = local.timestamp
    Builder   = "packer"
  }
}

# 빌드 블록: AMI 생성 시 수행할 작업 정의
build {
  sources = ["source.amazon-ebs.al2023_httpd"] # 위에서 정의한 소스를 참조

  # 쉘 프로비저너를 통해 인스턴스에 필요한 작업 실행
  provisioner "shell" {
    inline = [
      "sudo yum update -y",                 # 인스턴스 패키지 업데이트
      "sudo yum install httpd -y",          # Apache 웹 서버(httpd) 설치
      "sudo systemctl enable httpd --now"  # Apache 웹 서버 서비스 활성화 및 즉시 시작
    ]
  }
}
