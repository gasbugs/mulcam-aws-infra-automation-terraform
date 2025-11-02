# EC2 인스턴스에 적용할 보안 그룹 생성
resource "aws_security_group" "ec2_sg" {
  name   = "ec2-sg-ssh"
  vpc_id = module.vpc.vpc_id

  ingress {
    description = "Allow SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # 전 세계에서 SSH 허용
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # 모든 프로토콜 허용
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ec2-sg-ssh"
  }
}

module "ec2_instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "5.7.1"

  name = "al2023-ec2"

  instance_type               = "t3.micro"
  associate_public_ip_address = true

  ami = data.aws_ami.al2023.id

  key_name = aws_key_pair.my_key_pair.key_name # EC2에 연결할 SSH 키 이름

  vpc_security_group_ids = [aws_security_group.ec2_sg.id] # 보안 그룹 연결
  subnet_id              = module.vpc.public_subnets[0]   # 서브넷 ID

  # EC2 인스턴스 부팅 시 실행할 스크립트
  user_data = <<-EOF
              #!/bin/bash
              dnf update -y
              dnf install docker -y
              systemctl enable docker --now
              curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
              sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
              EOF
}

# 최신 Amazon Linux 2023 AMI 검색
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

# 랜덤 인트 생성 (1000 ~ 9999 범위)
resource "random_integer" "key_suffix" {
  min = 1000
  max = 9999
}

# 로컬 경로의 public key 읽기
resource "aws_key_pair" "my_key_pair" {
  key_name   = "my-key-${random_integer.key_suffix.result}" # 랜덤 인트 포함한 키 이름
  public_key = file(var.key_path)                           # 지정된 경로에서 public key 읽기
}
