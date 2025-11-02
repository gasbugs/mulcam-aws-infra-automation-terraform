# Terraform 및 AWS 프로바이더 버전 설정
terraform {
  required_version = ">= 1.13.4" # Terraform 최소 요구 버전
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 프로바이더의 소스 지정
      version = ">= 6.19.0"     # 6.19 버전 이상의 AWS 프로바이더 사용
    }
  }
}

# AWS 프로바이더 설정
provider "aws" {
  region  = var.aws_region # 리소스를 배포할 AWS 리전
  profile = "my-profile"   # 인증에 사용할 AWS CLI 프로파일
}

# 로컬 머신에 kubeconfig 설정을 자동으로 적용하기 위한 local-exec 프로비저너
resource "null_resource" "update_kubeconfig" {
  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
  }

  # 클러스터가 생성된 후 실행되도록 의존성 설정
  depends_on = [module.eks]
}
