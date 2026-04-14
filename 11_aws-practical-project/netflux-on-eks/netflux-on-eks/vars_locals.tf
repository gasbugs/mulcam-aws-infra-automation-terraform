data "aws_caller_identity" "current" {}

variable "tf_user" {
  default = "gasbugs"
}

variable "aws_region" {
  default = "us-east-1"
}

# AWS CLI 프로파일 이름 (kubeconfig 업데이트 시 올바른 자격증명 사용을 위해 명시)
variable "aws_profile" {
  description = "AWS CLI profile name used for kubeconfig update"
  default     = "my-profile"
}

#########################################
# cicd
# CodeCommit 저장소 이름 및 ECR 이미지 이름으로 사용되는 애플리케이션 이름
variable "app_name" {
  default = "netflux"
}


########################################
# S3
# 생성할 S3 버킷의 이름을 지정하는 변수
variable "bucket_name" {
  description = "Name of the S3 bucket for static website hosting"
  type        = string
  default     = "my-static-website-bucket"
}

# 정적 웹사이트의 기본 진입 파일 (보통 index.html)
variable "index_document" {
  description = "Name of the index document for the S3 static website (e.g. index.html)"
  type        = string
  default     = "index.html"
}

# 에러 발생 시 반환할 HTML 파일 이름
variable "error_document" {
  description = "Name of the error document for the S3 static website (e.g. error.html)"
  type        = string
  default     = "error.html"
}

# 로컬에서 업로드할 인덱스 문서 파일의 경로를 지정하는 변수
variable "index_document_path" {
  description = "Local path to the index HTML file to upload to S3"
  type        = string
  default     = "./html/index.html"
}

# 로컬에서 업로드할 에러 문서 파일의 경로를 지정하는 변수
variable "error_document_path" {
  description = "Local path to the error HTML file to upload to S3"
  type        = string
  default     = "./html/error.html"
}

# 리소스 환경 구분 태그 (dev, staging, prod 등)
variable "environment" {
  description = "Environment tag applied to all resources (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
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

variable "kubernetes_version" {
  description = "EKS 클러스터에 사용할 Kubernetes 버전 — 업그레이드 시 이 값만 변경하세요"
  type        = string
  default     = "1.35"
}
