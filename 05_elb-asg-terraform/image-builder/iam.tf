##############################################################################
# [iam.tf] Image Builder 빌드 인스턴스에 부여할 권한 설정
#
# IAM(Identity and Access Management)은 AWS 서비스 간 접근 권한을 관리합니다.
# Image Builder가 EC2를 띄워 AMI를 만들 때, 그 EC2 인스턴스는
# 여러 AWS 서비스에 접근해야 합니다. 이 파일이 그 권한을 정의합니다.
# 이 파일에서 정의하는 것:
#   - IAM Role: EC2 빌드 인스턴스의 신원 (어떤 서비스로서 동작하는지)
#   - EC2InstanceProfileForImageBuilder: AMI 생성·로그 전송 기본 권한
#   - AmazonSSMManagedInstanceCore: SSH 없이 SSM으로 인스턴스 접속 권한
#   - ImageBuilderS3LogsWrite: 빌드 로그를 S3에 기록하는 권한
#   - ImageBuilderCodeCommitPull: 소스 코드를 CodeCommit에서 가져오는 권한
#   - Instance Profile: EC2에 IAM Role을 연결하는 래퍼
#
# 역할 연결: infrastructure.tf가 이 Instance Profile을 빌드 EC2에 연결합니다.
##############################################################################

# IAM 역할 — EC2 빌드 인스턴스가 Image Builder 서비스와 통신할 때 사용하는 권한 묶음
resource "aws_iam_role" "image_builder" {
  name = "ImageBuilderRole-${var.environment}"

  # EC2 인스턴스가 이 역할을 맡을 수 있도록 허용 (Trust Policy)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "ImageBuilderRole"
    Environment = var.environment
  }
}

# Image Builder 기본 권한 — 빌드 로그 전송, AMI 생성 등 핵심 동작에 필요
resource "aws_iam_role_policy_attachment" "image_builder_core" {
  role       = aws_iam_role.image_builder.name
  policy_arn = "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder"
}

# SSM Agent 권한 — SSH 대신 SSM으로 빌드 인스턴스에 접속하기 위해 필요
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.image_builder.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# S3 로그 쓰기 권한 — 빌드 인스턴스가 AWSTOE 실행 로그를 S3에 업로드하기 위한 권한
resource "aws_iam_policy" "s3_logs_write" {
  name        = "ImageBuilderS3LogsWrite-${var.environment}"
  description = "Image Builder 빌드 인스턴스가 실행 로그를 S3 버킷에 기록할 수 있도록 허용"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.image_builder_artifacts.arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_logs_write" {
  role       = aws_iam_role.image_builder.name
  policy_arn = aws_iam_policy.s3_logs_write.arn
}

# CodeCommit 읽기 권한 — 빌드 인스턴스가 소스 코드를 git clone하기 위한 권한
resource "aws_iam_policy" "codecommit_pull" {
  name        = "ImageBuilderCodeCommitPull-${var.environment}"
  description = "Image Builder 빌드 인스턴스가 CodeCommit 저장소에서 소스를 pull할 수 있도록 허용"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "codecommit:GitPull",
          "codecommit:GetRepository"
        ]
        Resource = aws_codecommit_repository.spring_app.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "codecommit_pull" {
  role       = aws_iam_role.image_builder.name
  policy_arn = aws_iam_policy.codecommit_pull.arn
}

# 인스턴스 프로파일 — EC2에 IAM 역할을 붙이기 위한 래퍼 (EC2는 역할을 직접 받지 못하고 프로파일을 통해 받음)
resource "aws_iam_instance_profile" "image_builder" {
  name = "ImageBuilderInstanceProfile-${var.environment}"
  role = aws_iam_role.image_builder.name

  tags = {
    Name        = "ImageBuilderInstanceProfile"
    Environment = var.environment
  }
}
