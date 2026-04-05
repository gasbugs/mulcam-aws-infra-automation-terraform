# EC2 인스턴스 생성 — Aurora DB 접속 테스트용 클라이언트 서버
resource "aws_instance" "ec2_instance" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  key_name                    = aws_key_pair.ec2_key_pair.key_name
  associate_public_ip_address = true # 퍼블릭 IP 할당 (SSH 접속용)

  tags = {
    Name = var.instance_name
  }
}

# 랜덤 숫자 생성 — 키 페어 이름이 중복되지 않도록 고유 접미사로 사용
resource "random_integer" "random_number" {
  min = 1000
  max = 9999
}

# RSA 키 쌍 자동 생성 — 외부 키 파일 없이도 배포 가능하도록 Terraform이 직접 생성
resource "tls_private_key" "ec2_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# 생성된 프라이빗 키를 로컬 파일로 저장 — SSH 접속 시 사용
resource "local_file" "ec2_private_key" {
  content         = tls_private_key.ec2_key.private_key_pem
  filename        = "${path.root}/ec2-key.pem"
  file_permission = "0600" # 소유자만 읽을 수 있도록 권한 설정
}

# AWS에 퍼블릭 키 등록 — EC2 인스턴스가 이 키로 SSH 인증을 수행
resource "aws_key_pair" "ec2_key_pair" {
  key_name   = "ec2-key-pair-${random_integer.random_number.result}"
  public_key = tls_private_key.ec2_key.public_key_openssh
}

# EC2 인스턴스를 위한 보안 그룹 — SSH와 HTTP 인바운드 허용
resource "aws_security_group" "ec2_sg" {
  vpc_id      = var.vpc_id
  name_prefix = "ec2-public-sg-"

  # SSH 인바운드 허용 (학습 환경 — 실무에서는 특정 IP로 제한 권장)
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
    cidr_blocks = ["0.0.0.0/0"] # HTTP 접근 허용
  }

  # 모든 아웃바운드 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
