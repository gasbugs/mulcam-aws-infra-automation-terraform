data "aws_caller_identity" "current" {}

variable "tf_user" {
  default = "gasbugs"
}

variable "aws_region" {
  default = "us-east-1"
}

### locals
# S3 버킷 이름은 전역 유니크해야 하므로 랜덤 문자열로 suffix 생성
resource "random_string" "bucket_suffix" {
  length  = 8
  upper   = false
  special = false
}

locals {
  # 파이프라인에 사용할 이름 구성 (S3 버킷 이름 충돌 방지를 위해 랜덤 suffix 사용)
  subject     = "sample-pipeline"
  time_static = random_string.bucket_suffix.result # 기존 time_static 참조 호환용 alias
  name        = join("-", [local.subject, random_string.bucket_suffix.result])

  # 태그 구성
  tags = {
    Purpose      = local.subject
    Owner        = "Josh"
    Email        = "test@test.com"
    Team         = "DevOps"
    Organization = "BlackCompany"
  }

  # 배포할 리소스들에 대한 AWS 계정 정보
  account_id    = data.aws_caller_identity.current.account_id
  ecr_repo_name = "flask-example" # ECR 저장소 이름 (Flask 앱 이미지 저장)
}

# 유니크 ID — IAM 역할 이름 중복 방지용
resource "random_integer" "unique_id" {
  min = 1000
  max = 9999
}

variable "kubernetes_version" {
  description = "EKS 클러스터에 사용할 Kubernetes 버전 — 업그레이드 시 이 값만 변경하세요"
  type        = string
  default     = "1.35"
}
