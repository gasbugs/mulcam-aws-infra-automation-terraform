# Terraform 및 AWS 프로바이더 버전 설정
terraform {
  required_version = ">= 1.13.4" # Terraform 최소 요구 버전
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 프로바이더의 소스 지정
      version = "~> 6.0"     # 6.x.x 버전 이상의 AWS 프로바이더 사용 이상의 AWS 프로바이더 사용
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.7"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0"
    }
  }
}


# AWS 프로바이더 설정
provider "aws" {
  region  = var.aws_region # 리소스를 배포할 AWS 리전
  profile = "my-profile"   # 인증에 사용할 AWS CLI 프로파일
}

# AWS CLI로 kubeconfig를 업데이트하여 kubectl이 EKS 클러스터에 접근할 수 있도록 설정
resource "null_resource" "eks_kubectl_config" {
  provisioner "local-exec" {
    # aws eks update-kubeconfig: kubeconfig 파일에 클러스터 접근 정보를 자동 기록
    command = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region} --profile my-profile"
  }

  depends_on = [module.eks]
}

provider "kubectl" {
  load_config_file = true
}

provider "kubernetes" {
  config_path = "${pathexpand("~")}/.kube/config"
}

provider "helm" {
  kubernetes = {
    config_path = "${pathexpand("~")}/.kube/config"
  }
}
