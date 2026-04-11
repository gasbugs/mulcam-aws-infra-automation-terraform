# IAM 사용자 생성 — AWS 콘솔 또는 API에 접근할 수 있는 계정을 만드는 리소스
resource "aws_iam_user" "ec2_user" {
  name          = var.ec2_user_name
  path          = "/system/"
  force_destroy = false # 유저가 삭제될 때 그 유저의 모든 리소스를 강제로 삭제하지 않음
}

# 프로그래밍 방식 접근 키 생성 — CLI/SDK에서 사용할 Access Key와 Secret Key를 발급
resource "aws_iam_access_key" "ec2_user_key" {
  user = aws_iam_user.ec2_user.name
}

/*
# 콘솔 로그인 프로파일 — 웹 콘솔 접속을 위한 비밀번호 설정 (첫 로그인 시 변경 강제)
resource "aws_iam_user_login_profile" "secure_user_profile" {
  user                    = aws_iam_user.ec2_user.name
  password_reset_required = true # 유저가 처음 로그인 시 비밀번호 변경을 강제함
}
*/

# IAM 그룹 생성 — 여러 사용자에게 동일한 권한을 일괄 적용하기 위한 그룹
resource "aws_iam_group" "ec2_managers" {
  name = var.ec2_group_name
}

# 그룹 멤버십 설정 — 사용자를 특정 그룹에 추가하는 연결 리소스
resource "aws_iam_group_membership" "ec2_group_membership" {
  name  = "ec2-group"
  users = [aws_iam_user.ec2_user.name] # 그룹에 추가할 유저 목록
  group = aws_iam_group.ec2_managers.name
}

# 관리형 정책 연결 — AWS가 미리 만들어둔 EC2 전체 접근 권한을 그룹에 부여
resource "aws_iam_group_policy_attachment" "ec2_policy_attachment" {
  group      = aws_iam_group.ec2_managers.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess" # EC2에 대한 전체 액세스 권한을 가진 AWS 관리형 정책
}
