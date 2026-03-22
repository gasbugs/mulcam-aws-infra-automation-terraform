packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.8"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "ami_name" {
  type    = string
  default = "spring-boot-app-ami-{{timestamp}}"
}

source "amazon-ebs" "amazon-linux-2023" {
  ami_name      = var.ami_name
  instance_type = "t2.micro"
  region        = "us-east-1"
  
  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["137112412989"] # Amazon
  }
  ssh_username = "ec2-user"
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
