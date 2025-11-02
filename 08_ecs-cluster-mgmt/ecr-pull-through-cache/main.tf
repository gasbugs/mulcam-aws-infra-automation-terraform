# Create an ECR Repository
resource "aws_ecr_repository" "my_ecr_repo" {
  name                 = "my-ecr-repo"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "MyECRRepository"
  }
}

data "aws_caller_identity" "current" {}

# Set up a Pull-Through Cache Rule for Docker Hub
resource "aws_ecr_pull_through_cache_rule" "docker_hub" {
  ecr_repository_prefix = "docker.io"
  upstream_registry_url = "registry-1.docker.io"
  credential_arn        = aws_secretsmanager_secret_version.docker_hub_credentials_version.arn
  #credential_arn        = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:ecr-pullthroughcache/docker-hub-cred"
}

# AWS Secrets Manager에 비밀 생성
resource "aws_secretsmanager_secret" "docker_hub" {
  name = "ecr-pullthroughcache/docker-hub-cred"
}

resource "aws_secretsmanager_secret_version" "docker_hub_credentials_version" {
  secret_id = aws_secretsmanager_secret.docker_hub.id
  secret_string = jsonencode({
    username    = var.docker_hub_username
    accessToken = var.docker_hub_password
  })
}

# Amazon Linux 2023 AMI ID를 검색하는 데이터 소스 설정
data "aws_ami" "al2023" {
  most_recent = true       # 최신 AMI를 가져오도록 설정
  owners      = ["amazon"] # AMI 소유자가 Amazon인 것만 필터링

  filter {
    name   = "name"           # 필터 조건: 이름이 특정 패턴과 일치해야 함
    values = ["al2023-ami-*"] # Amazon Linux 2023 AMI 이름 패턴과 일치하는 값만 가져옴
  }

  filter {
    name   = "architecture" # 필터 조건: 아키텍처가 특정 값과 일치해야 함
    values = ["x86_64"]     # x86_64 아키텍처 AMI만 가져옴
  }
}

# AWS EC2 인스턴스 리소스를 정의
resource "aws_instance" "example" {
  ami                         = data.aws_ami.al2023.id # 위에서 정의한 Amazon Linux 2023 AMI ID를 사용
  instance_type               = "t2.micro"             # EC2 인스턴스 타입을 t2.micro로 설정
  associate_public_ip_address = true
  key_name                    = aws_key_pair.example.key_name
}

resource "random_integer" "random_name" {
  min = 10000
  max = 99999
}

resource "aws_key_pair" "example" {
  key_name   = "my-key-${random_integer.random_name.result}"
  public_key = file(var.key_path)
}
