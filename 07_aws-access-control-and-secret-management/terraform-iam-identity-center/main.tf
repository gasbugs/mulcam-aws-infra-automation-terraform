# AWS Identity Store에서 그룹 생성
resource "aws_identitystore_group" "sso_group" {
  identity_store_id = var.identity_store_id # AWS Identity Store의 고유 식별자
  display_name      = var.group_name        # 그룹의 표시 이름 (사용자에게 표시될 이름)
}

# AWS Identity Store에서 유저 생성
resource "aws_identitystore_user" "sso_user" {
  identity_store_id = var.identity_store_id # AWS Identity Store의 고유 식별자
  user_name         = var.user_display_name # 유저의 고유 이름 (로그인에 사용)
  display_name      = var.user_display_name # 유저의 표시 이름 (사용자에게 표시될 이름)

  name {
    given_name  = var.user_given_name  # 유저의 이름 (이름 부분)
    family_name = var.user_family_name # 유저의 성 (성 부분)
  }

  emails {
    value   = var.user_email # 유저의 이메일 주소
    primary = true           # 이 이메일을 해당 유저의 기본 이메일로 설정
  }
}

# 유저를 그룹에 추가 (옵션)
resource "aws_identitystore_group_membership" "sso_group_membership" {
  identity_store_id = var.identity_store_id                      # AWS Identity Store의 고유 식별자
  group_id          = aws_identitystore_group.sso_group.group_id # 유저를 추가할 그룹의 ID
  member_id         = aws_identitystore_user.sso_user.user_id    # 그룹에 추가할 유저의 ID
}

# AWS SSO Permission Set 생성
resource "aws_ssoadmin_permission_set" "sso_permission_set" {
  name             = "ReadOnlyAccess"                          # Permission Set의 이름
  description      = "SSO Permission Set for Read-Only Access" # Permission Set의 설명
  instance_arn     = var.sso_instance_arn                      # AWS SSO 인스턴스의 ARN
  session_duration = "PT4H"                                    # 세션 지속 시간을 4시간으로 설정

  # 태그 설정
  tags = {
    Environment = "Production" # "Production" 환경을 나타내는 태그
  }
}

# 특정 AWS 계정에 Permission Set 할당
resource "aws_ssoadmin_account_assignment" "account_assignment" {
  instance_arn       = var.sso_instance_arn                               # AWS SSO 인스턴스의 ARN
  permission_set_arn = aws_ssoadmin_permission_set.sso_permission_set.arn # 할당할 Permission Set의 ARN
  principal_id       = aws_identitystore_group.sso_group.group_id         # Permission Set을 할당할 그룹의 ID
  principal_type     = "GROUP"                                            # 할당할 주체의 유형 ("GROUP" 또는 "USER")
  target_id          = data.aws_caller_identity.current.account_id        # Permission Set을 할당할 대상 AWS 계정의 ID
  target_type        = "AWS_ACCOUNT"                                      # 할당 대상의 유형 (AWS 계정)
}
