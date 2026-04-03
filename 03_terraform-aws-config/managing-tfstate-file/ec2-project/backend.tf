# backend.tf
# Partial backend configuration — 실제 값은 backend.hcl에 정의됩니다.
# 초기화 명령: terraform init -backend-config=backend.hcl

terraform {
  backend "s3" {}
}
