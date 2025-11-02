# 지정된 리전의 기본 VPC를 가져옴
data "aws_vpc" "default" {
  default = true # 리전 내의 기본 VPC를 지정함
}

data "aws_caller_identity" "current" {}


# 1000에서 9999 사이의 랜덤한 숫자를 생성하여 키 이름에 사용
resource "random_integer" "unique_value" {
  min = 1000 # 랜덤 숫자의 최소값
  max = 9999 # 랜덤 숫자의 최대값
}

# S3 버킷 암호화를 위한 KMS 키 생성
resource "aws_kms_key" "s3_encryption_key" {
  description             = "KMS key for S3 encryption" # KMS 키 설명
  deletion_window_in_days = 30                          # 키 삭제 시 복구할 수 있는 기간 설정 (30일)
  enable_key_rotation     = true
  rotation_period_in_days = 90

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
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/ec2-s3-access-role"
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

# 랜덤한 숫자를 포함한 고유한 이름으로 S3 버킷 생성
resource "aws_s3_bucket" "example_bucket" {
  bucket = "${var.bucket_name}-${random_integer.unique_value.result}" # 변수와 랜덤 숫자를 사용한 버킷 이름
}

# KMS 키를 활용하여 S3 버킷의 서버 측 암호화 설정
resource "aws_s3_bucket_server_side_encryption_configuration" "example" {
  bucket = aws_s3_bucket.example_bucket.bucket

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3_encryption_key.arn # S3 버킷 암호화에 사용할 KMS 키의 ARN
      sse_algorithm     = "aws:kms"                         # KMS를 사용하여 암호화할 것임
    }
  }
}

# EC2 인스턴스가 S3에 접근할 수 있는 IAM 역할 생성
resource "aws_iam_role" "ec2_role" {
  name = "ec2-s3-access-role"

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

# EC2 인스턴스에 S3 및 KMS 접근 권한을 부여하는 IAM 정책 생성
resource "aws_iam_policy" "ec2_s3_kms_policy" {
  name = "ec2-s3-kms-access-policy"

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

# 역할에 정책을 연결
resource "aws_iam_role_policy_attachment" "ec2_role_kms_policy_attach" {
  role       = aws_iam_role.ec2_role.name           # 정책을 부여할 IAM 역할
  policy_arn = aws_iam_policy.ec2_s3_kms_policy.arn # 연결할 IAM 정책의 ARN
}

# EC2를 위한 인스턴스 프로파일 생성
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "ec2-s3-access-instance-profile"
  role = aws_iam_role.ec2_role.name # 역할과 연결
}

# EC2용 보안 그룹 생성
resource "aws_security_group" "ec2_security_group" {
  name_prefix = "ec2-sg-"
  description = "Allow SSH"
  vpc_id      = data.aws_vpc.default.id # 기본 VPC에 보안 그룹 생성

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

# AWS 키 페어 생성
resource "aws_key_pair" "ec2_key_pair" {
  key_name   = "ec2-key-${random_integer.unique_value.result}" # 랜덤한 숫자를 포함하는 키 이름 생성
  public_key = file(var.key_path)                              # 지정된 경로에서 public key 가져오기
}

# EC2 인스턴스 생성
resource "aws_instance" "example_ec2" {
  ami                  = var.ami_id                                         # 사용할 AMI ID
  instance_type        = "t2.micro"                                         # 인스턴스 유형
  iam_instance_profile = aws_iam_instance_profile.ec2_instance_profile.name # EC2 인스턴스에 할당할 IAM 인스턴스 프로파일
  security_groups      = [aws_security_group.ec2_security_group.name]       # EC2에 적용할 보안 그룹
  key_name             = aws_key_pair.ec2_key_pair.key_name                 # SSH 접속을 위한 키 페어 이름

  root_block_device {
    volume_size = 8                                 # 루트 볼륨 크기 (GiB)
    volume_type = "gp3"                             # 일반 SSD 타입
    encrypted   = true                              # 볼륨 암호화 활성화
    kms_key_id  = aws_kms_key.s3_encryption_key.arn # 암호화에 사용할 KMS 키의 ARN
  }

  tags = {
    Name = "EC2-with-S3-KMS-Access" # EC2 인스턴스에 적용할 태그
  }
}
