# 지정된 리전의 기본 VPC를 가져옴
data "aws_vpc" "default" {
  default = true # 리전 내의 기본 VPC를 지정함
}

# 현재 AWS 계정 정보 조회 — KMS 키 정책에서 계정 ID를 동적으로 참조
data "aws_caller_identity" "current" {}


# 키 이름 충돌 방지를 위한 랜덤 숫자 생성 — 동일 계정에서 여러 번 배포해도 키 이름이 겹치지 않음
resource "random_integer" "unique_value" {
  min = 1000 # 랜덤 숫자의 최소값
  max = 9999 # 랜덤 숫자의 최대값
}

# KMS 암호화 키 생성 — S3 데이터와 EC2 볼륨을 암호화하는 마스터 키
resource "aws_kms_key" "s3_encryption_key" {
  description             = "KMS key for S3 encryption" # KMS 키 설명
  deletion_window_in_days = 30                          # 키 삭제 시 복구할 수 있는 기간 설정 (30일)
  enable_key_rotation     = true
  rotation_period_in_days = 90

  # 리소스를 식별하고 환경을 구분하기 위한 태그
  tags = {
    Name        = "${var.environment}-s3-kms-key"
    Environment = var.environment
  }

  policy = jsonencode({
    Version = "2012-10-17",
    Id      = "kms-key-policy",
    Statement = [
      {
        Sid : "Enable IAM User Permissions",
        Effect : "Allow",
        Principal : {
          "AWS" : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/user0"
        },
        Action : "kms:*",
        Resource : "*"
      },
      {
        Sid    = "Allow use of the key by EC2 role",
        Effect = "Allow",
        Principal = {
          AWS = aws_iam_role.ec2_role.arn # IAM 역할 ARN을 직접 참조하여 이름 변경에 자동으로 대응
        },
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ],
        Resource = "*"
      }
    ]
  })
}

# KMS 키 별칭 설정 — 복잡한 키 ID 대신 알기 쉬운 이름으로 키를 관리
resource "aws_kms_alias" "s3_kms_key_alias" {
  name          = "alias/${var.environment}-s3-encryption-key"
  target_key_id = aws_kms_key.s3_encryption_key.key_id
}

# S3 버킷 생성 — KMS로 암호화되는 데이터 저장소
resource "aws_s3_bucket" "example_bucket" {
  bucket = "${var.bucket_name}-${random_integer.unique_value.result}" # 변수와 랜덤 숫자를 사용한 버킷 이름

  # 리소스를 식별하고 환경을 구분하기 위한 태그
  tags = {
    Name        = "${var.environment}-encrypted-bucket"
    Environment = var.environment
  }
}

# S3 서버 측 암호화 설정 — 버킷에 저장되는 모든 파일을 KMS 키로 자동 암호화
resource "aws_s3_bucket_server_side_encryption_configuration" "example" {
  bucket = aws_s3_bucket.example_bucket.bucket

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3_encryption_key.arn # S3 버킷 암호화에 사용할 KMS 키의 ARN
      sse_algorithm     = "aws:kms"                         # KMS를 사용하여 암호화할 것임
    }
  }
}

# S3 퍼블릭 접근 차단 — 버킷이 인터넷에 공개되는 것을 완전히 차단하는 보안 설정
resource "aws_s3_bucket_public_access_block" "example_bucket" {
  bucket = aws_s3_bucket.example_bucket.id

  block_public_acls       = true # 퍼블릭 ACL 차단
  block_public_policy     = true # 퍼블릭 버킷 정책 차단
  ignore_public_acls      = true # 기존 퍼블릭 ACL 무시
  restrict_public_buckets = true # 퍼블릭 버킷 제한
}

# S3 버전 관리 활성화 — 파일 수정/삭제 시 이전 버전을 보존하여 실수로 인한 데이터 손실 방지
resource "aws_s3_bucket_versioning" "example_bucket" {
  bucket = aws_s3_bucket.example_bucket.id

  versioning_configuration {
    status = "Enabled" # 버전 관리 활성화
  }
}

# S3 버킷 소유권 설정 — 버킷 소유자가 모든 객체를 소유하도록 강제 (ACL 불필요)
resource "aws_s3_bucket_ownership_controls" "example_bucket" {
  bucket = aws_s3_bucket.example_bucket.id

  rule {
    object_ownership = "BucketOwnerEnforced" # 버킷 소유자가 모든 객체 소유, ACL 비활성화
  }
}

# EC2 IAM 역할 생성 — EC2가 S3와 KMS에 접근할 수 있는 권한을 부여하는 역할
resource "aws_iam_role" "ec2_role" {
  name = "${var.environment}-ec2-s3-access-role" # 환경별로 구분되는 IAM 역할 이름

  # 리소스를 식별하고 환경을 구분하기 위한 태그
  tags = {
    Name        = "${var.environment}-ec2-s3-access-role"
    Environment = var.environment
  }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com" # EC2 서비스에 역할을 부여
      }
      Action = "sts:AssumeRole" # 역할을 가정할 수 있도록 허용
    }]
  })
}

# EC2 접근 정책 생성 — S3 읽기/쓰기와 KMS 암호화/복호화 권한을 정의
resource "aws_iam_policy" "ec2_s3_kms_policy" {
  name = "${var.environment}-ec2-s3-kms-policy" # 환경별로 구분되는 IAM 정책 이름

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject" # S3에서 객체를 가져오고 업로드할 수 있는 권한
        ]
        Resource = "${aws_s3_bucket.example_bucket.arn}/*" # 생성된 S3 버킷의 모든 객체에 대한 권한
      } /*, 이 권한은 명시하지 않아도 kms 리소스 기반 정책에서 허용되므로 필요 없음 // 명시적 거부에는 IAM 정책도 유용
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey" # KMS 키를 이용하여 데이터 키를 생성하고 복호화할 수 있는 권한
        ]
        Resource = aws_kms_key.s3_encryption_key.arn # 생성된 KMS 키에 대한 권한
      }*/
    ]
  })
}

# 역할에 정책 연결
resource "aws_iam_role_policy_attachment" "ec2_role_kms_policy_attach" {
  role       = aws_iam_role.ec2_role.name           # 정책을 부여할 IAM 역할
  policy_arn = aws_iam_policy.ec2_s3_kms_policy.arn # 연결할 IAM 정책의 ARN
}

# 인스턴스 프로파일 생성 — IAM 역할을 EC2에 연결하는 중간 매개체
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "${var.environment}-ec2-s3-access-profile" # 환경별로 구분되는 인스턴스 프로파일 이름
  role = aws_iam_role.ec2_role.name # 역할과 연결
}

# 보안 그룹 생성 — EC2에 대한 SSH(22번 포트) 접속을 허용하는 방화벽 규칙
resource "aws_security_group" "ec2_security_group" {
  name_prefix = "ec2-sg-"
  description = "Allow SSH"
  vpc_id      = data.aws_vpc.default.id # 기본 VPC에 보안 그룹 생성

  # 리소스를 식별하고 환경을 구분하기 위한 태그
  tags = {
    Name        = "${var.environment}-ec2-sg"
    Environment = var.environment
  }

  ingress {
    from_port   = 22 # SSH 포트
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # 모든 IP 주소에서 SSH 접속 허용
  }

  egress {
    from_port   = 0 # 모든 아웃바운드 트래픽 허용
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RSA 키 쌍 자동 생성 — 외부 파일 없이 Terraform이 직접 SSH 키를 생성
resource "tls_private_key" "ec2_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# AWS에 공개 키 등록 — EC2 접속 시 사용할 키페어를 AWS에 업로드
resource "aws_key_pair" "ec2_key_pair" {
  key_name   = "ec2-key-${random_integer.unique_value.result}" # 랜덤한 숫자를 포함하는 키 이름 생성
  public_key = tls_private_key.ec2_key.public_key_openssh      # Terraform이 생성한 공개 키 사용
}

# 프라이빗 키를 로컬 파일로 저장 — SSH 접속 시 사용할 .pem 파일 생성
resource "local_file" "private_key" {
  content         = tls_private_key.ec2_key.private_key_pem
  filename        = "${path.module}/ec2-key.pem"
  file_permission = "0400" # 소유자만 읽기 가능 (SSH 보안 요구사항)
}

# EC2 인스턴스 생성 — KMS로 암호화된 S3에 접근하는 실습용 서버
resource "aws_instance" "example_ec2" {
  ami                  = var.ami_id                                         # 사용할 AMI ID
  instance_type        = "t3.micro"                                         # 인스턴스 유형
  iam_instance_profile = aws_iam_instance_profile.ec2_instance_profile.name # EC2 인스턴스에 할당할 IAM 인스턴스 프로파일
  security_groups      = [aws_security_group.ec2_security_group.name]       # EC2에 적용할 보안 그룹
  key_name             = aws_key_pair.ec2_key_pair.key_name                 # SSH 접속을 위한 키 페어 이름

  root_block_device {
    volume_size = 8                                 # 루트 볼륨 크기 (GiB)
    volume_type = "gp3"                             # 일반 SSD 타입
    encrypted   = true                              # 볼륨 암호화 활성화
    kms_key_id  = aws_kms_key.s3_encryption_key.arn # 암호화에 사용할 KMS 키의 ARN
  }

  # 리소스를 식별하고 환경을 구분하기 위한 태그
  tags = {
    Name        = "${var.environment}-kms-demo-ec2"
    Environment = var.environment
  }
}
