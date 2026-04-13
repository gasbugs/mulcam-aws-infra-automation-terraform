###############
# 데이터 소스 — 기존 AWS 리소스를 조회하여 동적으로 값 참조

# 디폴트 VPC 조회 — 별도 VPC 생성 없이 AWS 기본 제공 VPC 사용
data "aws_vpc" "default" {
  default = true
}

# AL2023 최신 AMI 자동 조회 — 항상 최신 Amazon Linux 2023 이미지 사용
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

###############
# SSH 키 페어 — TLS 프로바이더로 RSA 키를 자동 생성하여 외부 파일 의존성 제거

# RSA 4096비트 키 생성 — 높은 보안 강도의 SSH 키
resource "tls_private_key" "main" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# 생성된 공개 키를 AWS에 등록 — EC2 접속 시 인증에 사용
resource "aws_key_pair" "main" {
  key_name   = "${local.name_prefix}-key"
  public_key = tls_private_key.main.public_key_openssh
}

# 프라이빗 키를 로컬 .pem 파일로 저장 — SSH 접속 시 -i 옵션으로 사용
resource "local_file" "private_key" {
  content         = tls_private_key.main.private_key_pem
  filename        = "${path.module}/docker-basics-key.pem"
  file_permission = "0400" # 소유자만 읽기 가능 (SSH 클라이언트 보안 요구사항)
}

###############
# 보안 그룹 — EC2에 허용할 인바운드/아웃바운드 트래픽 규칙 정의

# SSH(22)와 HTTP(80) 포트를 외부에 개방하는 방화벽 규칙
resource "aws_security_group" "main" {
  name        = "${local.name_prefix}-sg"
  description = "Allow SSH and HTTP access for Docker practice"
  vpc_id      = data.aws_vpc.default.id

  # SSH 접속 허용 — 터미널에서 EC2에 원격 접속하기 위한 포트
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # 실습 목적으로 전체 허용 (의도된 설정)
  }

  # HTTP 접속 허용 — 도커로 실행한 웹 서버를 브라우저에서 확인하기 위한 포트
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # 실습 목적으로 전체 허용 (의도된 설정)
  }

  # 아웃바운드 트래픽 전체 허용 — Docker 이미지 다운로드 등에 필요
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-sg"
  }
}

###############
# EC2 인스턴스 — Docker 실습용 서버

resource "aws_instance" "main" {
  ami           = data.aws_ami.al2023.id  # 최신 AL2023 AMI
  instance_type = var.instance_type       # 기본값: t3.micro

  key_name                    = aws_key_pair.main.key_name      # SSH 키페어 연결
  vpc_security_group_ids      = [aws_security_group.main.id]   # 보안 그룹 적용
  associate_public_ip_address = true                           # 공인 IP 자동 부여 — 외부 접근 허용 (의도된 설정)

  # 첫 부팅 시 Docker 자동 설치 스크립트 전달
  user_data = file("${path.module}/templates/user-data.sh")

  # 루트 볼륨 — Docker 이미지 저장 공간 확보를 위해 50GB 설정
  root_block_device {
    volume_type           = "gp3"          # 최신 범용 SSD 타입
    volume_size           = var.root_volume_size
    delete_on_termination = true           # 인스턴스 삭제 시 볼륨도 함께 삭제
    encrypted             = true           # 저장 데이터 암호화
  }

  tags = {
    Name = "${local.name_prefix}-server"
  }
}
