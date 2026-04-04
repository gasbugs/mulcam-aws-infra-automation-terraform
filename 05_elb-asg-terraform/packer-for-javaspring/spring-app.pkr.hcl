packer {
  required_plugins {
    # Amazon EBS 빌더 플러그인 — AMI를 구워내는 핵심 도구
    amazon = {
      version = "~> 1.3" # 마이너 버전 고정으로 예상치 못한 변경 방지
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# 배포 리전을 변수로 분리하여 재사용성 확보
variable "region" {
  type    = string
  default = "us-east-1"
}

# AMI 이름 접두사 (뒤에 타임스탬프가 자동 붙음)
variable "ami_name_prefix" {
  type    = string
  default = "spring-boot-app-ami"
}

locals {
  # 빌드 시각을 AMI 이름에 포함하여 중복 방지 (HCL2에서는 locals로 timestamp() 사용)
  timestamp = formatdate("YYYYMMDDhhmmss", timestamp())
}

source "amazon-ebs" "amazon-linux-2023" {
  ami_name      = "${var.ami_name_prefix}-${local.timestamp}"
  instance_type = "t3.micro"
  region        = var.region

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["137112412989"] # Amazon 공식 AMI
  }

  ssh_username = "ec2-user"

  # AMI에 태그를 달아 나중에 어떤 빌드인지 식별 가능하게 함
  tags = {
    Name      = "${var.ami_name_prefix}-${local.timestamp}"
    BuildDate = local.timestamp
    OS        = "Amazon Linux 2023"
    App       = "Spring Boot"
  }
}

build {
  sources = ["source.amazon-ebs.amazon-linux-2023"]

  # 1. 스크립트를 통한 패키지 설치
  provisioner "shell" {
    script = "./setup.sh"
  }

  # 2. 빌드된 Spring Boot JAR 파일 복사
  provisioner "file" {
    source      = "./target/demo-0.0.1-SNAPSHOT.jar"
    destination = "/home/ec2-user/app/demo-0.0.1-SNAPSHOT.jar"
  }

  # 3. Systemd 서비스 파일 복사
  provisioner "file" {
    source      = "./spring-app.service"
    destination = "/tmp/spring-app.service"
  }

  # 4. 서비스 등록 및 활성화
  provisioner "shell" {
    inline = [
      "sudo mv /tmp/spring-app.service /etc/systemd/system/spring-app.service",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable spring-app.service"
    ]
  }
}
