resource "aws_instance" "ec2_instance" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  key_name                    = aws_key_pair.ec2_key_pair.key_name
  associate_public_ip_address = true # Public IP 할당

  tags = {
    Name = var.instance_name
  }
}

resource "random_integer" "random_number" {
  min = 1000
  max = 9999
}

# RSA 키 쌍을 Terraform이 직접 생성 (외부 키 파일 없이도 어느 환경에서나 동작)
resource "tls_private_key" "ec2_key" {
  algorithm = "RSA"
  rsa_bits  = 4096 # 키 길이 (4096비트: 보안 강도 높음)
}

# 생성된 공개 키를 AWS에 등록하여 EC2 접속에 사용
resource "aws_key_pair" "ec2_key_pair" {
  key_name   = "ec2-key-pair-${random_integer.random_number.result}"
  public_key = tls_private_key.ec2_key.public_key_openssh # tls 리소스에서 공개 키 참조
}

# 프라이빗 키를 로컬 파일로 저장 (ssh -i ec2-key.pem ec2-user@<IP> 로 접속)
resource "local_file" "private_key" {
  content         = tls_private_key.ec2_key.private_key_pem # PEM 형식 프라이빗 키
  filename        = "${path.root}/ec2-key.pem"              # 루트 모듈 디렉터리에 저장
  file_permission = "0600"                                  # 소유자만 읽기 가능 (ssh 접속 요구사항)
}

# EC2 인스턴스를 위한 보안 그룹 생성 (SSH만 허용, DB 클라이언트 용도)
resource "aws_security_group" "ec2_sg" {
  vpc_id      = var.vpc_id
  name_prefix = "ec2-public-sg-"

  # SSH 인바운드 트래픽 허용 (allowed_ssh_cidr으로 접근 제한 가능)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr] # 관리자 IP 또는 VPN CIDR로 제한 권장
  }

  # 모든 아웃바운드 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
