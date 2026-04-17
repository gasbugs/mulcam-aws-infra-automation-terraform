# Terraform 및 프로바이더 버전 설정
terraform {
  required_version = ">= 1.13.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.16"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0" # ArgoCD 시크릿 및 Application 리소스 생성용
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0" # ArgoCD CodeCommit SSH 키 자동 생성용
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0" # ArgoCD Application CRD 배포용 (plan 단계 클러스터 연결 불필요)
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0" # S3 버킷 이름 유니크 suffix 생성용
    }
  }
}

# AWS 프로바이더 설정
provider "aws" {
  region  = var.aws_region
  profile = "my-profile"
}

# Helm 프로바이더 v3 — kubernetes 속성 할당 방식(= {}) + exec 인증
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

# Kubernetes 프로바이더 — ArgoCD 시크릿 및 Application 리소스 생성에 사용
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

# kubectl 프로바이더 — ArgoCD Application CRD 배포용
# kubernetes_manifest와 달리 plan 단계에서 클러스터 연결을 시도하지 않음
provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name,
                   "--region", var.aws_region, "--profile", "my-profile"]
  }
}
