# 현재 AWS 계정 ID를 가져오기 위한 데이터 소스 선언
data "aws_caller_identity" "current" {}

# S3 읽기 전용 정책을 JSON 파일로부터 불러옴
resource "aws_iam_policy" "s3_readonly_policy" {
  name        = "S3ReadOnlyPolicy"
  description = "Read-only access to S3 buckets"
  policy      = file(var.s3_policy_file)
}

# S3 읽기 정책을 사용할 수 있는 역할 생성
resource "aws_iam_role" "s3_read_role" {
  name = "S3ReadOnlyRole"
  assume_role_policy = jsonencode({
    "Version" = "2012-10-17",
    "Statement" = [
      {
        "Effect" = "Allow",
        "Principal" = {
          "AWS" = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${aws_iam_user.example_user.name}"
        },
        "Action" = "sts:AssumeRole"
      }
    ]
  })
}

# 역할에 S3 읽기 전용 정책 연결
resource "aws_iam_role_policy_attachment" "s3_policy_attach" {
  role       = aws_iam_role.s3_read_role.name
  policy_arn = aws_iam_policy.s3_readonly_policy.arn
}

# IAM 유저 생성
resource "aws_iam_user" "example_user" {
  name = var.user_name
  path = "/"
}

# 생성한 유저에 대한 Access Key 생성 (프로그래밍적 접근을 위해 사용)
resource "aws_iam_access_key" "example_user_key" {
  user = aws_iam_user.example_user.name
}
