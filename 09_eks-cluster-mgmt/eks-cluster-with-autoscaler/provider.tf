# Terraform 및 AWS 프로바이더 버전 설정
terraform {
  required_version = ">= 1.13.4" # Terraform 최소 요구 버전
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 프로바이더의 소스 지정
      version = "~> 6.0"     # 6.x.x 버전 이상의 AWS 프로바이더 사용
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.7"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
  }
}

# AWS 프로바이더 설정
provider "aws" {
  region  = var.aws_region # 리소스를 배포할 AWS 리전
  profile = "my-profile"   # 인증에 사용할 AWS CLI 프로파일
}

# Helm 프로바이더 v3 — kubernetes 속성 할당 방식(= {}) 사용
# module.eks가 생성된 후 클러스터 정보가 확정되므로 단일 terraform apply로 배포 가능
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    # aws eks get-token으로 임시 Bearer 토큰을 발급받아 Kubernetes API 인증
    # kubeconfig 파일 없이 동작 — CI/CD 환경에서도 사용 가능
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name,
                     "--region", var.aws_region, "--profile", "my-profile"]
    }
  }
}

# Kubernetes 프로바이더 — helm 프로바이더와 동일한 exec 인증 방식 사용
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name,
                   "--region", var.aws_region, "--profile", "my-profile"]
  }
}
