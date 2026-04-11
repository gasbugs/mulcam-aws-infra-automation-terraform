# 디폴트 VPC 정보 조회
data "aws_vpc" "default" {
  default = true
}

# 보안 그룹 생성 — SSH(22번 포트) 접속만 허용하는 방화벽 규칙
resource "aws_security_group" "ssh_sg" {
  name        = "ssh-access-sg"
  description = "Allow SSH access"
  vpc_id      = data.aws_vpc.default.id # 디폴트 VPC ID 사용

  # 리소스를 식별하고 환경을 구분하기 위한 태그
  tags = {
    Name        = "${var.environment}-ec2-sg"
    Environment = var.environment
  }

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

# 키 이름 충돌 방지를 위한 랜덤 숫자 생성
resource "random_integer" "key_name" {
  min = 1000
  max = 9999
}

# RSA 키 쌍 자동 생성 — 외부 파일 없이 Terraform이 직접 SSH 키를 생성
resource "tls_private_key" "ec2_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# AWS에 공개 키 등록 — EC2 접속 시 사용할 키페어를 AWS에 업로드
resource "aws_key_pair" "ec2_key_pair" {
  key_name   = "ec2-key-${random_integer.key_name.result}" # 랜덤한 숫자를 포함하는 키 이름 생성
  public_key = tls_private_key.ec2_key.public_key_openssh  # TLS 프로바이더가 생성한 공개 키 사용
}

# 프라이빗 키를 로컬 파일로 저장 — SSH 접속 시 사용할 .pem 파일 생성
resource "local_file" "private_key" {
  content         = tls_private_key.ec2_key.private_key_pem
  filename        = "${path.module}/ec2-key.pem"
  file_permission = "0400" # 소유자만 읽기 가능 (SSH 보안 요구사항)
}

# AL2023 최신 AMI 자동 조회 — 항상 최신 이미지를 사용하도록 동적으로 조회
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

# EC2 인스턴스 생성 — Secrets Manager에서 시크릿 값을 읽어오는 실습용 서버
resource "aws_instance" "ec2_instance" {
  ami                  = data.aws_ami.al2023.id                             # AMI ID는 동적으로 조회한 최신 AL2023 사용
  instance_type        = "t3.micro"                                         # 인스턴스 타입 설정
  key_name             = aws_key_pair.ec2_key_pair.key_name                 # 생성된 키 페어 이름 사용
  iam_instance_profile = aws_iam_instance_profile.ec2_instance_profile.name # IAM 인스턴스 프로파일 연결

  # SSH 연결을 위해 생성한 보안 그룹 적용
  vpc_security_group_ids = [aws_security_group.ssh_sg.id]

  # 리소스를 식별하고 환경을 구분하기 위한 태그
  tags = {
    Name        = "${var.environment}-secrets-demo-ec2"
    Environment = var.environment
  }
}

# 인스턴스 프로파일 생성 — IAM 역할을 EC2에 연결하는 중간 매개체
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "${var.environment}-ec2-secrets-manager-profile" # 환경별로 구분되는 인스턴스 프로파일 이름
  role = aws_iam_role.ec2_secrets_manager_role.name
}

# EC2 IAM 역할 생성 — EC2 인스턴스가 AWS 서비스에 접근할 수 있도록 권한을 부여하는 역할
resource "aws_iam_role" "ec2_secrets_manager_role" {
  name = "${var.environment}-ec2-secrets-manager-role" # 환경별로 구분되는 IAM 역할 이름

  # 리소스를 식별하고 환경을 구분하기 위한 태그
  tags = {
    Name        = "${var.environment}-ec2-secrets-role"
    Environment = var.environment
  }

  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "ec2.amazonaws.com"
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
}

# Secrets Manager 읽기 정책 — 특정 시크릿만 읽을 수 있는 최소 권한 정책
resource "aws_iam_policy" "secrets_manager_policy" {
  name        = "${var.environment}-secrets-manager-access-policy" # 환경별로 구분되는 IAM 정책 이름
  description = "Policy to allow EC2 access to Secrets Manager"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "secretsmanager:GetSecretValue"
        ],
        "Resource" : var.secret_arn
      }
    ]
  })
}

# 역할에 정책 연결
resource "aws_iam_role_policy_attachment" "attach_policy" {
  role       = aws_iam_role.ec2_secrets_manager_role.name
  policy_arn = aws_iam_policy.secrets_manager_policy.arn
}
