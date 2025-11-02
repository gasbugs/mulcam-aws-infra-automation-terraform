variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
}

variable "aws_profile" {
  description = "AWS profile for all resources"
  type        = string
}


variable "group_name" {
  description = "팀 이름"
  type        = string
}

variable "user_display_name" {
  description = "유저 이름"
  type        = string
}

variable "user_given_name" {
  description = "Firt name"
  type        = string
}

variable "user_family_name" {
  description = "Last name"
  type        = string
}

variable "principal_type" {
  description = "The type of principal (USER or GROUP)"
  type        = string
  default     = "USER"
}


# 프로파일에 추가할 이메일 정보, 여기로 계정 정보가 전달됨
variable "user_email" {
  description = "프로파일에 추가할 이메일 정보, 여기로 계정 정보가 전달됨"
  type        = string
}


data "aws_caller_identity" "current" {}
/*
variable "aws_account_id" {
  description = "The AWS account ID where the permission set will be assigned"
  type        = string
  default     = data.aws_caller_identity.current.account_id
}
*/

# AWS CLI를 사용해 SSO 인스턴스의 ARN을 가져옴
# aws sso-admin list-instances --query 'Instances[0].InstanceArn' --output text
variable "sso_instance_arn" {
  description = "AWS CLI를 사용해 SSO 인스턴스의 ARN을 가져옴"
  type        = string
}

#AWS CLI를 사용해 Identity Store ID를 가져옴
# aws sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text
variable "identity_store_id" {
  description = "AWS CLI를 사용해 Identity Store ID를 가져옴"
  type        = string
}
