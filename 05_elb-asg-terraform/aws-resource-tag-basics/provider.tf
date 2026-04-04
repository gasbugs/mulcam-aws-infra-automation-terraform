# AWS 프로바이더 설정: 리소스를 어느 리전·계정으로 배포할지 지정
provider "aws" {
  region  = var.aws_region  # 리소스를 배포할 AWS 리전
  profile = var.aws_profile # 인증에 사용할 AWS CLI 프로파일

  # 모든 리소스에 자동으로 붙는 공통 태그 (프로바이더 수준에서 일괄 적용)
  default_tags {
    tags = {
      Environment = var.environment
      Owner       = var.owner
    }
  }
}
