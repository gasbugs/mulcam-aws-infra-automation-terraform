# 실제 AWS 연결 설정 — 어느 리전에, 어떤 자격증명으로 접속할지 정의
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  # 모든 리소스에 공통 태그 자동 부착
  default_tags {
    tags = local.common_tags
  }
}
