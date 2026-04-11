# 현재 AWS 계정 정보 조회 — 정책에서 계정 ID를 동적으로 참조하기 위해 사용
data "aws_caller_identity" "current" {}

# 커스텀 IAM 정책 생성 — 특정 서비스/작업만 허용하는 권한 규칙을 정의
resource "aws_iam_policy" "s3_readonly_policy" {
  name        = "S3ReadOnlyPolicy"
  description = "Read-only access to S3 buckets"
  policy      = file(var.s3_policy_file)
}

# IAM 역할 생성 — 사용자가 역할을 위임(AssumeRole)받아 추가 권한을 얻을 수 있는 구조
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

# 역할에 정책 연결 — 생성한 IAM 정책을 역할에 부여
resource "aws_iam_role_policy_attachment" "s3_policy_attach" {
  role       = aws_iam_role.s3_read_role.name
  policy_arn = aws_iam_policy.s3_readonly_policy.arn
}

# IAM 사용자 생성 — 역할 위임을 실습할 테스트 사용자
resource "aws_iam_user" "example_user" {
  name = var.user_name
  path = "/"
}

# 프로그래밍 방식 접근 키 생성 — CLI에서 역할 위임 테스트에 사용할 자격증명
resource "aws_iam_access_key" "example_user_key" {
  user = aws_iam_user.example_user.name
}
