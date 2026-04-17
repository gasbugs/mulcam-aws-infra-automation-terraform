# ================================================================
# Terraform 프로바이더 설정
#
# 프로바이더(Provider)란?
#   Terraform이 AWS, Kubernetes 등 외부 시스템과 대화할 때 필요한 "번역기"
#   각 프로바이더는 특정 서비스의 API를 Terraform 언어로 사용할 수 있게 해줌
# ================================================================
terraform {
  required_version = ">= 1.13.4"
  required_providers {
    # AWS 리소스(EC2, EKS, IAM 등) 생성에 사용
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Kubernetes 클러스터에 Helm 차트(패키지)를 설치할 때 사용
    # ArgoCD를 Helm으로 설치하기 위해 필요
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.16"
    }
    # Kubernetes 리소스(Secret, ConfigMap 등)를 Terraform으로 직접 생성할 때 사용
    # ArgoCD 레포지토리 인증 Secret 생성에 활용
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
    # TLS 인증서·SSH 키 쌍을 Terraform 내부에서 생성할 때 사용
    # ArgoCD가 CodeCommit에 SSH로 접속하기 위한 키를 자동 생성
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    # Kubernetes CRD(사용자 정의 리소스)를 plan 단계에서 클러스터 없이도 배포 가능
    # ArgoCD Application 리소스 배포에 사용 (kubernetes_manifest는 plan 시 클러스터 필요)
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0"
    }
    # 랜덤 문자열·숫자 생성에 사용
    # S3 버킷 이름 suffix, IAM 역할 이름 suffix 등에 활용
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

# AWS 프로바이더 — 리소스를 배포할 리전과 자격증명 프로파일 지정
# profile = "my-profile": ~/.aws/config에 설정된 named profile 사용
provider "aws" {
  region  = var.aws_region
  profile = "my-profile"
}

# Helm 프로바이더 — EKS 클러스터에 Helm 차트 설치
# EKS가 완전히 생성된 후에 클러스터 엔드포인트가 확정되므로
# exec 블록으로 동적으로 토큰을 발급받아 인증
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint                              # EKS API 서버 주소
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data) # 클러스터 CA 인증서

    # aws eks get-token 명령으로 임시 인증 토큰 발급
    # kubeconfig 파일 없이 동작 — 다른 환경(CI/CD)에서도 사용 가능
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name,
                     "--region", var.aws_region, "--profile", "my-profile"]
    }
  }
}

# Kubernetes 프로바이더 — Secret, ConfigMap 등 K8s 네이티브 리소스 생성
# Helm 프로바이더와 동일한 인증 방식 사용
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

# kubectl 프로바이더 — ArgoCD Application CRD처럼 kubernetes_manifest로 배포 불가한 리소스에 사용
# kubernetes_manifest와의 차이: plan 단계에서 클러스터 연결 시도를 하지 않아
# 클러스터 생성과 리소스 배포를 한 번의 apply로 처리 가능
provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false # kubeconfig 파일 무시 — exec 인증만 사용

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name,
                   "--region", var.aws_region, "--profile", "my-profile"]
  }
}
