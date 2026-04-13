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
      source  = "hashicorp/time" # EKS 준비 대기(time_sleep)와 타임스탬프(time_static) 사용
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

# EKS 클러스터 생성 후 kubectl 설정 파일을 자동으로 업데이트하는 리소스
# terraform_data는 null_resource를 대체하는 최신 방식 (Terraform 1.4.0+)
resource "terraform_data" "eks_kubectl_config" {
  provisioner "local-exec" {
    # eksctl 명령으로 로컬 ~/.kube/config 파일에 EKS 클러스터 접속 정보 등록
    command = "eksctl utils write-kubeconfig --cluster ${module.eks.cluster_name} --region ${var.aws_region}"
  }

  # EKS가 완전히 준비된 후 실행 (60초 대기 후)
  depends_on = [time_sleep.wait_for_eks]
}

# EKS 클러스터가 완전히 준비될 때까지 60초 대기
# (EKS API 서버가 응답 가능한 상태가 되기까지 시간이 필요)
resource "time_sleep" "wait_for_eks" {
  depends_on = [module.eks]

  create_duration = "60s" # 60초 대기
}

# Helm 프로바이더: ArgoCD 등 Helm 차트를 EKS 클러스터에 설치하기 위한 설정
provider "helm" {
  kubernetes = {
    config_path = "${pathexpand("~")}/.kube/config" # 로컬 kubectl 설정 파일 경로
  }
}
