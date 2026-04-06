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

# EC2 인스턴스를 위한 보안 그룹 — 규칙은 별도 리소스로 분리 (AWS provider 6.x 권장)
resource "aws_security_group" "ec2_sg" {
  vpc_id      = var.vpc_id
  name_prefix = "ec2-public-sg-"
  description = "Security group for EC2 DB client instance"
}

# SSH 인바운드 허용 규칙 (학습 환경 — 실무에서는 특정 IP로 제한 권장)
resource "aws_vpc_security_group_ingress_rule" "ec2_ssh" {
  security_group_id = aws_security_group.ec2_sg.id
  description       = "Allow SSH access (restrict to specific IP in production)"
  cidr_ipv4         = "0.0.0.0/0" # 학습 환경용 전체 허용
  from_port         = 22           # SSH 포트
  to_port           = 22
  ip_protocol       = "tcp"
}

# HTTP 인바운드 허용 규칙
resource "aws_vpc_security_group_ingress_rule" "ec2_http" {
  security_group_id = aws_security_group.ec2_sg.id
  description       = "Allow HTTP access"
  cidr_ipv4         = "0.0.0.0/0" # HTTP 접근 허용
  from_port         = 80           # HTTP 포트
  to_port           = 80
  ip_protocol       = "tcp"
}

# 모든 아웃바운드 트래픽 허용 규칙
resource "aws_vpc_security_group_egress_rule" "ec2_all" {
  security_group_id = aws_security_group.ec2_sg.id
  description       = "Allow all outbound traffic"
  cidr_ipv4         = "0.0.0.0/0" # 모든 대상으로 출력 허용
  ip_protocol       = "-1"        # 모든 프로토콜 허용
}
