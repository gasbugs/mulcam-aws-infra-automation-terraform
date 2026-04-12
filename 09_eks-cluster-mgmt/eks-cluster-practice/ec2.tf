# SSH 연결을 위한 보안 그룹 생성 (22번 포트 오픈)
# 이름에 랜덤 문자열을 붙여 재배포 시 이름 충돌을 방지
resource "aws_security_group" "ssh_sg" {
  name        = "ssh-access-sg-${random_string.suffix.result}"
  description = "Allow SSH access"
  vpc_id      = module.vpc.vpc_id # 디폴트 VPC ID 사용

  ingress {
    from_port   = 22 # SSH 포트
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # 모든 IP 주소에서 접근 허용 (주의: 실제 사용 시 IP 제한 필요)
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # 모든 프로토콜 허용
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 1000에서 9999 사이의 랜덤한 숫자를 생성하여 키 이름에 사용
resource "random_integer" "key_name" {
  min = 1000
  max = 9999
}

# TLS 프로바이더로 RSA 4096비트 키 쌍을 자동 생성 (외부 키 파일 없이 Terraform이 직접 관리)
resource "tls_private_key" "ec2_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# 생성된 공개 키를 AWS에 등록
resource "aws_key_pair" "ec2_key_pair" {
  key_name   = "ec2-key-${random_integer.key_name.result}"    # 랜덤한 숫자를 포함하는 키 이름 생성
  public_key = tls_private_key.ec2_key.public_key_openssh     # TLS로 생성된 공개 키 사용
}

# 개인 키를 로컬 파일로 저장 (SSH 접속 시 사용, 권한 0600으로 보안 설정)
resource "local_file" "private_key" {
  content         = tls_private_key.ec2_key.private_key_pem
  filename        = "${path.module}/ec2-key.pem"
  file_permission = "0600"
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

# EC2 인스턴스 생성
resource "aws_instance" "ec2_instance" {
  ami           = data.aws_ami.al2023.image_id       # AMI ID는 변수로 입력받음
  instance_type = "t3.micro"                         # 인스턴스 타입 설정
  key_name      = aws_key_pair.ec2_key_pair.key_name # 생성된 키 페어 이름 사용

  associate_public_ip_address = true
  subnet_id                   = module.vpc.public_subnets[0]

  # SSH 연결을 위해 생성한 보안 그룹 적용
  vpc_security_group_ids = [aws_security_group.ssh_sg.id]
}

