data "aws_caller_identity" "current" {}

variable "tf_user" {
  default = "gasbugs"
}

variable "aws_region" {
  default = "us-east-1"
}

variable "project_name" {
  default = "gasbugs/my-cicd-app"
}

variable "app_name" {
  default = "my-cicd-app"
}

### locals
resource "random_string" "webhook_secret" {
  length  = 32
  special = true
  upper   = true
  lower   = true
  numeric = true
}

resource "time_static" "this" {
  # 이 tf 파일에서 생성되는 리소스들의 이름에서 suffix로 사용하기 위함
}

locals {
  # 웹 훅에 사용할 시크릿 
  github_webhook_secret = random_string.webhook_secret.result

  # 파이프라인에 사용할 이름 구성
  subject     = var.app_name
  time_static = formatdate("YYYYMMDDHHmm", time_static.this.rfc3339)
  name        = join("-", [local.subject, local.time_static])

  # 태그 구성
  tags = {
    Purpose      = local.subject
    Owner        = "Ilsun Choi"
    Email        = "ilsunchoi@cloudsecuritylab.co.kr"
    Team         = "DevOps"
    Organization = "cloudsecuritylab"
  }

  # 배포할 리소스들(CodeBuild, CodePipeline, LogGroup, EventRule, EventTarget)에 대한 aws 정보들
  account_id    = data.aws_caller_identity.current.account_id
  ecr_repo_name = var.app_name
}

# 유니크 ID
resource "random_integer" "unique_id" {
  min = 1000
  max = 9999
}
