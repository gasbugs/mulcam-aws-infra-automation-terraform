# EC2 보안 그룹 — SSH 및 Redis 포트 접근을 제어하는 방화벽 규칙 모음
resource "aws_security_group" "ec2_sg" {
  name        = "${var.project_name}-ec2-sg"
  description = "Security group for EC2 instances"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-ec2-sg"
  }
}

# SSH 인바운드 허용 — 허용된 CIDR 목록에서 22번 포트 접근 가능
resource "aws_vpc_security_group_ingress_rule" "ec2_ssh" {
  for_each          = toset(var.allowed_ssh_cidr_blocks)
  security_group_id = aws_security_group.ec2_sg.id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "Allow SSH access"
}

# Redis 포트 인바운드 허용 — EC2에서 Redis(6379)로의 아웃바운드 응답 트래픽 허용
resource "aws_vpc_security_group_ingress_rule" "ec2_redis" {
  for_each          = toset(var.redis_cidr_blocks)
  security_group_id = aws_security_group.ec2_sg.id
  cidr_ipv4         = each.value
  from_port         = 6379
  to_port           = 6379
  ip_protocol       = "tcp"
  description       = "Allow Redis port access"
}

# 모든 아웃바운드 트래픽 허용 — 외부 인터넷 및 AWS 서비스 통신용
resource "aws_vpc_security_group_egress_rule" "ec2_all" {
  security_group_id = aws_security_group.ec2_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # 모든 프로토콜 허용
  description       = "Allow all outbound traffic"
}

# RSA 키 자동 생성 — 외부 키 파일 없이 Terraform 실행만으로 SSH 키 쌍 완성
resource "tls_private_key" "ec2_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# 생성된 공개 키를 AWS에 Key Pair로 등록
resource "aws_key_pair" "my_key_pair" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ec2_key.public_key_openssh

  tags = {
    Name = "${var.project_name}-key"
  }
}

# 프라이빗 키를 로컬 파일로 저장 — SSH 접속 시 사용 (권한 0600 설정)
resource "local_file" "private_key" {
  content         = tls_private_key.ec2_key.private_key_pem
  filename        = "${path.module}/ec2-key.pem"
  file_permission = "0600"
}

# EC2 인스턴스 생성 — 퍼블릭 서브넷에 배포하여 SSH 및 인터넷 접근 가능
resource "aws_instance" "ec2_instance" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  key_name                    = aws_key_pair.my_key_pair.key_name
  associate_public_ip_address = true

  iam_instance_profile = var.ec2_instance_profile

  user_data = var.user_data

  tags = {
    Name = "${var.project_name}-ec2-instance"
  }
}
