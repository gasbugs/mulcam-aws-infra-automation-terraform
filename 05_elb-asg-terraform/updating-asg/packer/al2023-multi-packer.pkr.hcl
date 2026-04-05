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

# [V1 소스] 구버전 AMI — ASG 업데이트 실습에서 초기 배포에 사용할 이미지
source "amazon-ebs" "al2023_httpd_v1" {
  profile         = var.profile
  region          = var.aws_region
  instance_type   = var.instance_type
  ssh_username    = "ec2-user"                                              # Amazon Linux 기본 SSH 사용자
  source_ami      = data.amazon-ami.al2023.id                              # 위에서 조회한 최신 AL2023 AMI 사용
  ami_name        = "httpd-v1-${local.timestamp}"                          # 타임스탬프로 이름 중복 방지
  ami_description = "Amazon Linux 2023 with Apache httpd v1 - built by Packer" # AMI 설명 (ASCII만 허용)

  # 생성된 AMI에 태그 추가 — v1/v2 구분 및 빌드 날짜 기록
  tags = {
    Name      = "httpd-v1"
    Version   = "v1"
    BuildDate = local.timestamp
    Builder   = "packer"
  }
}

# [V2 소스] 신버전 AMI — ASG 업데이트 실습에서 교체 대상 이미지 (instance_refresh 트리거 후 배포됨)
source "amazon-ebs" "al2023_httpd_v2" {
  profile         = var.profile
  region          = var.aws_region
  instance_type   = var.instance_type
  ssh_username    = "ec2-user"
  source_ami      = data.amazon-ami.al2023.id
  ami_name        = "httpd-v2-${local.timestamp}"
  ami_description = "Amazon Linux 2023 with Apache httpd v2 - built by Packer" # AMI 설명 (ASCII만 허용)

  tags = {
    Name      = "httpd-v2"
    Version   = "v2"
    BuildDate = local.timestamp
    Builder   = "packer"
  }
}

# 빌드 블록: v1, v2 두 소스를 동시에 빌드 (병렬 실행)
build {
  sources = [
    "source.amazon-ebs.al2023_httpd_v1",
    "source.amazon-ebs.al2023_httpd_v2",
  ]

  # 공통 프로비저너: 두 이미지 모두 httpd 설치 및 활성화
  provisioner "shell" {
    inline = [
      "sudo yum update -y",                # 인스턴스 패키지 업데이트
      "sudo yum install httpd -y",         # Apache 웹 서버(httpd) 설치
      "sudo systemctl enable httpd --now", # Apache 웹 서버 서비스 활성화 및 즉시 시작
    ]
  }

  # V1 전용 프로비저너: 구버전임을 나타내는 index.html 생성 (실습 시 브라우저로 버전 확인 가능)
  provisioner "shell" {
    only = ["amazon-ebs.al2023_httpd_v1"] # v1 소스에만 적용

    inline = [
      "echo '<h1>Version 1 - Hello from old server!</h1>' | sudo tee /var/www/html/index.html",
    ]
  }

  # V2 전용 프로비저너: 신버전임을 나타내는 index.html 생성 (롤링 업데이트 완료 후 변경된 내용 확인용)
  provisioner "shell" {
    only = ["amazon-ebs.al2023_httpd_v2"] # v2 소스에만 적용

    inline = [
      "echo '<h1>Version 2 - Hello from new server!</h1>' | sudo tee /var/www/html/index.html",
    ]
  }
}
