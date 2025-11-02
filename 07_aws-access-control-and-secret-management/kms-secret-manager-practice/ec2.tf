# SSH 연결을 위한 보안 그룹 생성 (22번 포트 오픈)
resource "aws_security_group" "ssh_sg" {
  name        = "ssh-access-sg"
  description = "Allow SSH access"
  vpc_id      = module.vpc.vpc_id

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

# AWS 키 페어 생성
resource "aws_key_pair" "ec2_key_pair" {
  key_name   = "ec2-key-${random_integer.key_name.result}" # 랜덤한 숫자를 포함하는 키 이름 생성
  public_key = file(var.key_path)                          # 지정된 경로에서 public key 가져오기
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
  ami                         = data.aws_ami.al2023.id                             # AMI ID는 변수로 입력받음
  instance_type               = "t2.micro"                                         # 인스턴스 타입 설정
  key_name                    = aws_key_pair.ec2_key_pair.key_name                 # 생성된 키 페어 이름 사용
  iam_instance_profile        = aws_iam_instance_profile.ec2_instance_profile.name # IAM 인스턴스 프로파일 연결
  associate_public_ip_address = true
  subnet_id                   = module.vpc.public_subnets[0]

  # SSH 연결을 위해 생성한 보안 그룹 적용
  vpc_security_group_ids = [aws_security_group.ssh_sg.id]
}

# EC2 인스턴스에 연결할 IAM 인스턴스 프로파일 생성
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "EC2SecretsManagerInstanceProfile"
  role = aws_iam_role.ec2_secrets_manager_role.name
}

resource "aws_iam_role" "ec2_secrets_manager_role" {
  name = "EC2SecretsManagerRole"

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

data "aws_caller_identity" "current" {}

resource "aws_iam_policy" "secrets_manager_policy" {
  name        = "SecretsManagerAccessPolicy"
  description = "Policy to allow EC2 access to Secrets Manager"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "secretsmanager:GetSecretValue"
        ],
        "Resource" : aws_rds_cluster.my_aurora_cluster.master_user_secret[0].secret_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_policy" {
  role       = aws_iam_role.ec2_secrets_manager_role.name
  policy_arn = aws_iam_policy.secrets_manager_policy.arn
}

