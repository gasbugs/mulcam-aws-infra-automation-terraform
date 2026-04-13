###############
# Secret Manager를 활용한 RDS 패스워드와 교체를 위한 람다 설정

# Secrets Manager 암호화 KMS 키 — 시크릿 데이터를 암호화할 마스터 키
resource "aws_kms_key" "example_key" {
  description             = var.kms_description
  deletion_window_in_days = 30   # 키 삭제 시 복구할 수 있는 기간 (30일)
  enable_key_rotation     = true # 1년 주기로 KMS 키 자동 교체 (보안 모범사례)
}

# KMS 키 별칭 설정 — Secrets Manager 암호화 키를 별칭으로 쉽게 식별
resource "aws_kms_alias" "secrets_kms_key_alias" {
  name          = "alias/${var.environment}-secrets-manager-key"
  target_key_id = aws_kms_key.example_key.key_id
}

# 고유한 시크릿 이름 생성을 위한 랜덤 숫자
resource "random_integer" "secret_suffix" {
  min = 1000
  max = 9999
}

# 시크릿 컨테이너 생성 — 비밀번호 등 민감 정보를 저장하는 금고를 AWS에 생성
resource "aws_secretsmanager_secret" "example_secret" {
  name        = "${var.secret_name}-${random_integer.secret_suffix.result}"
  description = var.secret_description
  kms_key_id  = aws_kms_key.example_key.arn
}

# 시크릿 초기 비밀번호 생성 — 복잡한 비밀번호를 자동으로 만들어 Secrets Manager에 저장
resource "random_string" "example" {
  length  = 16    # 생성할 문자열의 길이
  special = false # 특수문자 포함 여부
  upper   = true  # 대문자 포함 여부
  lower   = true  # 소문자 포함 여부
  numeric = true  # 숫자 포함 여부
}

# 시크릿 초기값 설정 — JSON 형식으로 사용자명과 비밀번호를 금고에 저장
resource "aws_secretsmanager_secret_version" "example_secret_version" {
  secret_id = aws_secretsmanager_secret.example_secret.id
  secret_string = jsonencode({
    "username" = var.secret_username
    "password" = resource.random_string.example.result
  })
}

# Lambda 코드 패키징 — Python 소스 파일을 ZIP으로 묶어 Lambda에 업로드
data "archive_file" "rotate_secret" {
  type = "zip" # ZIP 파일 형식

  source_dir  = "${path.module}/lambda"            # ZIP으로 압축할 소스 디렉터리
  output_path = "${path.module}/rotate_secret.zip" # 생성된 ZIP 파일 경로
}

# 비밀번호 로테이션 Lambda 함수 — 30일마다 자동으로 비밀번호를 교체하는 함수
resource "aws_lambda_function" "rotate_secret" {
  function_name = var.lambda_function_name
  role          = aws_iam_role.lambda_secrets_manager_role.arn
  handler       = "rotate_secret.lambda_handler"
  runtime       = "python3.12" # Python 3.12 런타임 (python3.8은 2024년 10월 EOL)

  # Lambda 코드 (Zip 파일로 저장됨)
  filename         = data.archive_file.rotate_secret.output_path
  source_code_hash = filebase64sha256(data.archive_file.rotate_secret.output_path)

  environment {
    variables = {
      SECRET_ID = aws_secretsmanager_secret.example_secret.id
    }
  }
}

# Lambda 실행 역할 — Lambda 함수가 Secrets Manager와 KMS에 접근할 수 있는 IAM 역할
resource "aws_iam_role" "lambda_secrets_manager_role" {
  name = "lambda-secrets-manager-role"

  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "lambda.amazonaws.com"
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
}

# Lambda Secrets Manager 접근 정책 — 시크릿 읽기/쓰기 권한을 Lambda에 부여
resource "aws_iam_policy" "lambda_secrets_manager_policy" {
  name        = "lambda-secrets-manager-policy"
  description = "Policy to allow Lambda to access Secrets Manager and CloudWatch Logs"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "secretsmanager:PutSecretValue",
          "secretsmanager:GetSecretValue"
        ],
        "Resource" : aws_secretsmanager_secret.example_secret.arn
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        "Resource" : "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# 역할에 정책 연결 — Lambda 역할에 Secrets Manager 접근 권한을 부여
resource "aws_iam_role_policy_attachment" "attach_lambda_policy" {
  role       = aws_iam_role.lambda_secrets_manager_role.name
  policy_arn = aws_iam_policy.lambda_secrets_manager_policy.arn
}

# Lambda KMS 접근 정책 — 시크릿 암호화/복호화에 필요한 KMS 권한
resource "aws_iam_policy" "lambda_kms_policy" {
  name        = "LambdaKMSAccessPolicy"
  description = "Policy to allow Lambda to use the KMS key for Secrets Manager"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:ReEncrypt*"
        ],
        "Resource" : aws_kms_key.example_key.arn
      }
    ]
  })
}

# 역할에 정책 연결 — Lambda 역할에 KMS 암호화 권한을 부여
resource "aws_iam_role_policy_attachment" "attach_kms_policy" {
  role       = aws_iam_role.lambda_secrets_manager_role.name
  policy_arn = aws_iam_policy.lambda_kms_policy.arn
}

# 자동 로테이션 설정 — Lambda를 통해 30일 주기로 시크릿을 자동 갱신
resource "aws_secretsmanager_secret_rotation" "example" {
  secret_id           = aws_secretsmanager_secret.example_secret.id
  rotation_lambda_arn = aws_lambda_function.rotate_secret.arn


  rotation_rules {
    automatically_after_days = 30 # 30일마다 시크릿 로테이션
  }
}

# Lambda 호출 권한 — Secrets Manager가 Lambda 함수를 실행할 수 있도록 허용
resource "aws_lambda_permission" "allow_secrets_manager" {
  statement_id  = "AllowSecretsManagerInvocation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotate_secret.function_name
  principal     = "secretsmanager.amazonaws.com"
}

###############
# EC2 인스턴스 — Secrets Manager에서 시크릿 값을 직접 읽어보는 실습용 서버

# 디폴트 VPC 정보 조회 — 별도 VPC 없이 기본 제공 VPC 사용
data "aws_vpc" "default" {
  default = true
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

# 보안 그룹 — SSH(22번 포트) 접속만 허용하는 방화벽 규칙
resource "aws_security_group" "ssh_sg" {
  name        = "${var.environment}-ssh-access-sg"
  description = "Allow SSH access"
  vpc_id      = data.aws_vpc.default.id # 디폴트 VPC ID 사용

  ingress {
    from_port   = 22 # SSH 포트
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # 모든 IP 주소에서 접근 허용 (실습용)
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # 모든 아웃바운드 트래픽 허용
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-ssh-sg"
    Environment = var.environment
  }
}

# RSA 키 쌍 자동 생성 — 외부 파일 없이 Terraform이 직접 SSH 키를 생성
resource "tls_private_key" "ec2_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# AWS에 공개 키 등록 — EC2 접속 시 사용할 키페어를 AWS에 업로드
resource "aws_key_pair" "ec2_key_pair" {
  key_name   = "ec2-key-${random_integer.secret_suffix.result}" # 시크릿과 같은 랜덤 숫자로 키 이름 생성
  public_key = tls_private_key.ec2_key.public_key_openssh       # TLS 프로바이더가 생성한 공개 키 사용
}

# 프라이빗 키를 로컬 파일로 저장 — SSH 접속 시 사용할 .pem 파일 생성
resource "local_file" "private_key" {
  content         = tls_private_key.ec2_key.private_key_pem
  filename        = "${path.module}/ec2-key.pem"
  file_permission = "0400" # 소유자만 읽기 가능 (SSH 보안 요구사항)
}

# EC2 IAM 역할 — 인스턴스가 Secrets Manager에 직접 접근할 수 있는 권한 부여
resource "aws_iam_role" "ec2_secrets_manager_role" {
  name = "${var.environment}-ec2-secrets-manager-role"

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

  tags = {
    Name        = "${var.environment}-ec2-secrets-role"
    Environment = var.environment
  }
}

# Secrets Manager 읽기 정책 — 이 프로젝트에서 생성한 시크릿만 읽을 수 있는 최소 권한
resource "aws_iam_policy" "ec2_secrets_manager_policy" {
  name        = "${var.environment}-ec2-secrets-manager-access-policy"
  description = "Policy to allow EC2 to read the secret from Secrets Manager"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "secretsmanager:GetSecretValue"
        ],
        "Resource" : aws_secretsmanager_secret.example_secret.arn
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "kms:Decrypt"
        ],
        "Resource" : aws_kms_key.example_key.arn
      }
    ]
  })
}

# 역할에 정책 연결 — EC2 역할에 Secrets Manager 읽기 권한 부여
resource "aws_iam_role_policy_attachment" "attach_ec2_secrets_policy" {
  role       = aws_iam_role.ec2_secrets_manager_role.name
  policy_arn = aws_iam_policy.ec2_secrets_manager_policy.arn
}

# 인스턴스 프로파일 — IAM 역할을 EC2에 연결하는 중간 매개체
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "${var.environment}-ec2-secrets-manager-profile"
  role = aws_iam_role.ec2_secrets_manager_role.name
}

# EC2 인스턴스 생성 — Secrets Manager에서 시크릿 값을 읽어오는 실습용 서버
resource "aws_instance" "ec2_instance" {
  ami                    = data.aws_ami.al2023.id                              # 최신 AL2023 AMI 사용
  instance_type          = "t3.micro"                                          # 무료 티어 호환 인스턴스 타입
  key_name               = aws_key_pair.ec2_key_pair.key_name                  # 생성된 키페어 연결
  iam_instance_profile   = aws_iam_instance_profile.ec2_instance_profile.name # IAM 프로파일 연결
  vpc_security_group_ids = [aws_security_group.ssh_sg.id]                      # SSH 보안 그룹 적용

  tags = {
    Name        = "${var.environment}-secrets-demo-ec2"
    Environment = var.environment
  }
}
