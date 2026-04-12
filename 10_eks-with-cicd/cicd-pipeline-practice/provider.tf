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
  }
}

# AWS 프로바이더 설정
provider "aws" {
  region  = var.aws_region
  profile = "my-profile"
}

# EKS kubeconfig 자동 설정 — ArgoCD Helm 설치 전에 kubeconfig 준비
resource "null_resource" "eks_kubectl_config" {
  provisioner "local-exec" {
    command = "eksctl utils write-kubeconfig --cluster ${module.eks.cluster_name} --region ${var.aws_region}"
  }

  depends_on = [time_sleep.wait_for_eks]
}

resource "time_sleep" "wait_for_eks" {
  depends_on = [module.eks]

  create_duration = "60s"
}

# Helm 프로바이더 — ArgoCD 설치에 사용
provider "helm" {
  kubernetes = {
    config_path = "${pathexpand("~")}/.kube/config"
  }
}

# Kubernetes 프로바이더 — ArgoCD 시크릿 및 Application 리소스 생성에 사용
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.aws_region,
      "--profile", "my-profile"
    ]
  }
}
