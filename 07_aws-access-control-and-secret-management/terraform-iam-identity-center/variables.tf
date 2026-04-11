# 입력 변수 정의 — IAM Identity Center(SSO) 설정에 필요한 외부 값

# AWS 리소스를 배포할 리전을 지정하는 변수
variable "aws_region" {
  description = "AWS 리소스를 생성할 리전 (예: us-east-1)"
  type        = string
  default     = "us-east-1"
}

# AWS CLI 자격증명 프로파일을 지정하는 변수
variable "aws_profile" {
  description = "AWS CLI에 설정된 자격증명 프로파일 이름"
  type        = string
  default     = "my-profile"
}

# SSO 그룹 이름을 지정하는 변수
variable "group_name" {
  description = "IAM Identity Center에 생성할 그룹 이름 (예: 팀 이름)"
  type        = string
}

# SSO 사용자의 표시 이름을 지정하는 변수
variable "user_display_name" {
  description = "SSO 사용자의 표시 이름 (로그인 화면에 보이는 이름)"
  type        = string
}

# SSO 사용자의 이름(First name)을 지정하는 변수
variable "user_given_name" {
  description = "SSO 사용자의 이름 (First name)"
  type        = string
}

# SSO 사용자의 성(Last name)을 지정하는 변수
variable "user_family_name" {
  description = "SSO 사용자의 성 (Last name)"
  type        = string
}

# 권한 집합을 할당할 주체(대상) 유형을 지정하는 변수
variable "principal_type" {
  description = "권한 집합을 부여할 대상 유형 (USER: 개인 사용자, GROUP: 그룹)"
  type        = string
  default     = "USER"
}

# SSO 로그인 초대 이메일을 받을 주소를 지정하는 변수
variable "user_email" {
  description = "SSO 사용자의 이메일 주소 — 이 주소로 로그인 초대 메일이 전송됨"
  type        = string
}

# AWS IAM Identity Center 인스턴스 ARN을 지정하는 변수
# 조회 방법: aws sso-admin list-instances --query 'Instances[0].InstanceArn' --output text
variable "sso_instance_arn" {
  description = "AWS IAM Identity Center 인스턴스 ARN (aws sso-admin list-instances로 조회)"
  type        = string
}

# Identity Store ID를 지정하는 변수
# 조회 방법: aws sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text
variable "identity_store_id" {
  description = "Identity Store ID (aws sso-admin list-instances로 조회)"
  type        = string
}
