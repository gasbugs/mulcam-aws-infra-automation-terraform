# Terraform 및 프로바이더 버전 설정
terraform {
  # 실제 릴리스된 버전 기준으로 최소 요구 버전 설정 (terraform_data 지원 버전)
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 리소스 관리용 프로바이더
      version = "~> 6.0"        # AWS 프로바이더 6.x 버전 사용
    }
    helm = {
      source  = "hashicorp/helm" # Kubernetes Helm 차트 배포용 프로바이더
      version = ">= 3.1.0"       # Helm 프로바이더 3.1.0 이상 사용
    }
    kubernetes = {
      source  = "hashicorp/kubernetes" # Kubernetes 리소스(네임스페이스, 서비스 등) 관리용 프로바이더
      version = ">= 2.23.0"
    }
    time = {
      source  = "hashicorp/time" # 타임스탬프(time_static) 사용
      version = ">= 0.9.0"
    }
    random = {
      source  = "hashicorp/random" # 고유 이름 생성을 위한 랜덤 문자열/숫자 사용
      version = ">= 3.5.0"
    }
  }
}

# AWS 프로바이더 설정
provider "aws" {
  region  = var.aws_region # 리소스를 배포할 AWS 리전
  profile = "my-profile"   # 인증에 사용할 AWS CLI 프로파일
}

# Kubernetes 프로바이더 — EKS 모듈 output을 직접 참조하는 exec 방식
# 이 방식의 장점:
#   - kubeconfig 파일 불필요 (파일 시스템 상태에 무관하므로 CI/CD 환경에서도 안정적)
#   - EKS 클러스터 output을 직접 참조하므로 Terraform이 의존 순서를 자동으로 파악
#   - terraform_data + kubeconfig 방식은 depends_on이 누락되면 provider가 잘못 초기화될 위험 있음
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint                                  # EKS API 서버 주소
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data) # 클러스터 CA 인증서

  # exec 블록: apply 시점에 aws eks get-token으로 임시 토큰을 발급받아 인증
  # kubeconfig 파일 대신 AWS CLI가 직접 토큰을 생성하므로 kubeconfig 의존성 없음
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region, "--profile", "my-profile"]
  }
}

# Helm 프로바이더 v3 — kubernetes 설정을 attribute 방식으로 지정 (v3에서 블록 문법 변경)
# v3부터 'kubernetes { ... }' 블록 대신 'kubernetes = { ... }' attribute 방식 사용
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region, "--profile", "my-profile"]
    }
  }
}
