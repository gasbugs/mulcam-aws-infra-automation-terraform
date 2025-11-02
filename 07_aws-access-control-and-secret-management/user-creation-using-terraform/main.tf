# EC2를 관리할 유저를 생성
resource "aws_iam_user" "ec2_user" {
  name          = var.ec2_user_name
  path          = "/system/"
  force_destroy = false # 유저가 삭제될 때 그 유저의 모든 리소스를 강제로 삭제하지 않음
}

# 생성한 유저에 대한 Access Key 생성 (프로그래밍적 접근을 위해 사용)
resource "aws_iam_access_key" "ec2_user_key" {
  user = aws_iam_user.ec2_user.name
}

/*
# 콘솔 접근을 허용하는 로그인 프로필 설정
resource "aws_iam_user_login_profile" "secure_user_profile" {
  user                    = aws_iam_user.ec2_user.name
  password_reset_required = true # 유저가 처음 로그인 시 비밀번호 변경을 강제함
}
*/

# EC2를 관리할 IAM 그룹 생성
resource "aws_iam_group" "ec2_managers" {
  name = var.ec2_group_name
}

# 생성한 유저를 'ec2-managers' 그룹에 추가
resource "aws_iam_group_membership" "ec2_group_membership" {
  name  = "ec2-group"
  users = [aws_iam_user.ec2_user.name] # 그룹에 추가할 유저 목록
  group = aws_iam_group.ec2_managers.name
}

# EC2 관련 관리형 정책(AmazonEC2FullAccess)을 그룹에 연결하여 권한 부여
resource "aws_iam_group_policy_attachment" "ec2_policy_attachment" {
  group      = aws_iam_group.ec2_managers.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess" # EC2에 대한 전체 액세스 권한을 가진 AWS 관리형 정책
}
