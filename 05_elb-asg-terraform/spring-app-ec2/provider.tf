# AWS 프로바이더 설정 — 리소스를 배포할 리전과 인증 프로파일 지정
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}
