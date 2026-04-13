locals {
  # 모든 리소스에 일괄 적용되는 공통 태그
  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.project_name
  }

  # 리소스 이름에 사용되는 접두사 — 환경과 프로젝트 이름 조합
  name_prefix = "${var.project_name}-${var.environment}"
}
