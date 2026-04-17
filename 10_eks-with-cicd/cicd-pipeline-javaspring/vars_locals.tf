# 현재 AWS 계정 정보 조회 — 계정 ID를 IAM 정책 ARN 구성 시 사용
data "aws_caller_identity" "current" {}

# Terraform을 실행하는 사용자 이름 (리소스 태그나 이름 구분에 활용)
variable "tf_user" {
  default = "gasbugs"
}

# AWS 리소스를 배포할 리전 (지역) — us-east-1은 미국 동부 버지니아 리전
variable "aws_region" {
  default = "us-east-1"
}

### 공통 이름 및 태그 구성 ###

# S3 버킷 이름은 전 세계에서 유일(globally unique)해야 함
# 같은 이름의 버킷이 이미 존재하면 생성 실패 → 랜덤 8자리 소문자+숫자로 suffix 생성
resource "random_string" "bucket_suffix" {
  length  = 8
  upper   = false # 대문자 제외 (S3 버킷 이름은 소문자만 허용)
  special = false # 특수문자 제외
}

locals {
  # 이 프로젝트에서 생성되는 모든 리소스 이름의 기반
  # 예: javaspring-pipeline-a1b2c3d4
  subject     = "javaspring-pipeline"
  time_static = random_string.bucket_suffix.result # 기존 코드에서 time_static을 참조하는 곳과의 호환성 유지
  name        = join("-", [local.subject, random_string.bucket_suffix.result])

  # 비용 추적·관리·책임자 식별을 위한 태그 — AWS 콘솔에서 리소스 검색에 활용
  tags = {
    Purpose      = local.subject
    Owner        = "gasbugs"
    Email        = "ilsunchoi@cloudsecuritylab.co.kr"
    Team         = "DevOps"
    Organization = "cloudsecuritylab"
  }

  # 현재 AWS 계정 ID — IAM 정책의 ARN(Amazon Resource Name) 구성에 필요
  account_id    = data.aws_caller_identity.current.account_id

  # ECR 저장소 이름 — Docker 이미지를 저장할 창고 이름
  # CodeBuild가 빌드한 Java Spring Boot 이미지를 이 이름으로 저장함
  ecr_repo_name = "javaspring"
}

# IAM 역할 이름 중복 방지용 4자리 랜덤 숫자
# AWS IAM 역할 이름은 계정 내에서 유일해야 하므로 suffix로 추가
resource "random_integer" "unique_id" {
  min = 1000
  max = 9999
}

# EKS 클러스터에 설치할 Kubernetes 버전
# 업그레이드가 필요할 때 이 값만 변경하면 됨 (예: "1.35" → "1.36")
variable "kubernetes_version" {
  description = "EKS 클러스터에 사용할 Kubernetes 버전 — 업그레이드 시 이 값만 변경하세요"
  type        = string
  default     = "1.35"
}
