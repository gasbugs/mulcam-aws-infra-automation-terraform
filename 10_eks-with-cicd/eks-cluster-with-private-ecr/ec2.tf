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

# ECR 접근 권한을 EC2에 부여하기 위한 IAM 역할 생성
resource "aws_iam_role" "ec2_role" {
  name = "ec2-ecr-access-role"

  # EC2 서비스가 이 역할을 맡을(assume) 수 있도록 허용
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# ECR 전체 접근 권한(push/pull) 부여 — EC2에서 이미지를 빌드하고 푸시할 수 있도록 설정
resource "aws_iam_role_policy_attachment" "ec2_ecr_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
}

# EC2 → EKS 클러스터 조회 권한 부여 (aws eks update-kubeconfig 실행 시 필요)
# AmazonEKSClusterPolicy는 클러스터 서비스 역할용이므로 직접 정책을 인라인으로 부여
resource "aws_iam_role_policy" "ec2_eks_describe" {
  name = "eks-describe-policy"
  role = aws_iam_role.ec2_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster", "eks:ListClusters"]
      Resource = "*"
    }]
  })
}

# IAM 인스턴스 프로파일 — EC2 인스턴스에 IAM 역할을 연결하기 위한 중간 오브젝트
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-ecr-access-profile"
  role = aws_iam_role.ec2_role.name
}

module "ec2_instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 6.0" # AWS 프로바이더 v6와 호환되는 최신 버전 (5.x는 cpu_core_count 등 제거된 인수 포함)

  name = "al2023-ec2"

  instance_type               = "t3.micro"
  associate_public_ip_address = true

  ami = data.aws_ami.al2023.id

  key_name             = aws_key_pair.my_key_pair.key_name          # EC2에 연결할 SSH 키 이름
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name  # ECR/EKS 접근 IAM 프로파일

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

# TLS 프로바이더로 RSA 4096비트 키 쌍 자동 생성 (외부 파일 없이 Terraform이 직접 관리)
resource "tls_private_key" "ec2_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# 생성된 공개 키를 AWS에 등록
resource "aws_key_pair" "my_key_pair" {
  key_name   = "my-key-${random_integer.key_suffix.result}"  # 랜덤 인트 포함한 키 이름
  public_key = tls_private_key.ec2_key.public_key_openssh    # TLS로 생성된 공개 키 사용
}

# 개인 키를 로컬 파일로 저장 (SSH 접속 시 사용, 권한 0600으로 보안 설정)
resource "local_file" "private_key" {
  content         = tls_private_key.ec2_key.private_key_pem
  filename        = "${path.module}/ec2-key.pem"
  file_permission = "0600"
}
