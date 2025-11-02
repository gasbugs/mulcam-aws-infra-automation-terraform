data "aws_caller_identity" "current" {}

variable "tf_user" {
  default = "gasbugs"
}

variable "aws_region" {
  default = "us-east-1"
}

#########################################
# cicd
variable "project_name" {
  default = "gasbugs/netflux-app"
}

variable "app_name" {
  default = "netflux"
}


########################################
# S3
# 생성할 S3 버킷의 이름을 지정하는 변수
variable "bucket_name" {
  description = "S3 버킷의 이름" # 변수에 대한 설명
  type        = string      # 변수 타입
  default     = "my-static-website-bucket"
}

# 인덱스 문서의 이름을 지정하는 변수 (예: index.html)
variable "index_document" {
  description = "인덱스 문서의 이름 (예: index.html)" # 변수에 대한 설명
  type        = string                       # 변수 타입
  default     = "index.html"                 # 기본값
}

# 에러 문서의 이름을 지정하는 변수 (예: error.html)
variable "error_document" {
  description = "에러 문서의 이름 (예: error.html)" # 변수에 대한 설명
  type        = string                      # 변수 타입
  default     = "error.html"                # 기본값
}

# 로컬에서 업로드할 인덱스 문서 파일의 경로를 지정하는 변수
variable "index_document_path" {
  description = "로컬 인덱스 문서 파일의 경로" # 변수에 대한 설명
  type        = string             # 변수 타입
  default     = "./html/index.html"
}

# 로컬에서 업로드할 에러 문서 파일의 경로를 지정하는 변수
variable "error_document_path" {
  description = "로컬 에러 문서 파일의 경로" # 변수에 대한 설명
  type        = string            # 변수 타입
  default     = "./html/error.html"
}

# S3 버킷에 적용할 환경 태그를 지정하는 변수 (예: dev, prod)
variable "environment" {
  description = "버킷의 환경 태그 (예: dev, prod)" # 변수에 대한 설명
  type        = string                     # 변수 타입
  default     = "dev"                      # 기본값
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
