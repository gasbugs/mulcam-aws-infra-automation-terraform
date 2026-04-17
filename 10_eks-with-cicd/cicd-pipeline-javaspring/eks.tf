# ================================================================
# EKS(Elastic Kubernetes Service) 클러스터 구성
#
# EKS란?
#   AWS가 관리해주는 Kubernetes 서비스
#   Kubernetes: 컨테이너(Docker)를 자동으로 배포·관리·확장하는 시스템
#   직접 설치하면 복잡한 마스터 노드 운영을 AWS가 대신 해줌
# ================================================================

# EKS 클러스터 생성 — terraform-aws-modules/eks 공개 모듈 사용
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.8"

  name               = local.cluster_name   # 클러스터 이름 (예: education-eks-abcd1234)
  kubernetes_version = var.kubernetes_version

  # 퍼블릭 액세스 허용 — 로컬 PC에서 kubectl로 클러스터 접근 가능
  endpoint_public_access = true

  # Terraform을 실행한 IAM 사용자에게 자동으로 클러스터 관리자 권한 부여
  # 이 설정이 없으면 apply 후 kubectl 명령이 거부될 수 있음
  enable_cluster_creator_admin_permissions = true

  # 클러스터 기본 애드온(추가 기능)
  # 노드 그룹 생성 전에 설치해야 하는 DaemonSet 기반 애드온만 여기에 포함
  # DaemonSet: 모든 노드에 1개씩 자동 배포되는 파드 유형
  addons = {
    # kube-proxy: 클러스터 내부 네트워크 규칙 관리 (서비스 → 파드 트래픽 라우팅)
    kube-proxy = {}

    # eks-pod-identity-agent: 파드가 IAM 역할을 사용할 수 있게 해주는 에이전트
    # 노드보다 먼저 설치해야 노드 부팅 시 바로 작동
    eks-pod-identity-agent = {
      before_compute = true
    }

    # vpc-cni: 파드에 VPC IP 주소를 직접 할당하는 네트워크 플러그인
    # 노드보다 먼저 설치해야 노드 부팅 시 네트워크가 정상 구성됨
    vpc-cni = {
      before_compute = true
    }
  }

  # EKS 컨트롤 플레인과 워커 노드가 사용할 VPC와 서브넷
  # 프라이빗 서브넷에 노드를 배치해 직접 인터넷 노출을 차단
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
}

# ================================================================
# EKS 관리형 노드 그룹 — 실제 애플리케이션이 실행될 워커 노드(EC2 서버)
#
# 노드 그룹을 EKS 모듈과 분리하는 이유:
#   coredns, aws-ebs-csi-driver는 Deployment 기반 애드온으로
#   실제 노드가 존재해야 파드를 스케줄링할 수 있음
#   → 노드 그룹 먼저 생성 → 이후 Deployment 기반 애드온 설치
# ================================================================
module "eks_managed_node_groups" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "21.8"

  name                 = "on_demand"          # 온디맨드 인스턴스 (스팟 인스턴스 대비 안정적)
  cluster_name         = module.eks.cluster_name
  kubernetes_version   = module.eks.cluster_version      # 클러스터 버전과 동일하게 유지
  cluster_service_cidr = module.eks.cluster_service_cidr # 서비스 IP 대역 (클러스터와 일치해야 함)
  subnet_ids           = module.vpc.private_subnets      # 프라이빗 서브넷에 노드 배치

  ami_type       = "AL2023_x86_64_STANDARD" # Amazon Linux 2023 (최신 AWS 공식 OS)
  instance_types = ["c5.large"]             # 2 vCPU, 4GB RAM — ArgoCD + Spring Boot 실행에 적합

  # 오토스케일링 설정 — 트래픽에 따라 노드 수 자동 조절
  min_size     = 1 # 최소 노드 수 (비용 절감용)
  max_size     = 3 # 최대 노드 수 (트래픽 급증 대비)
  desired_size = 2 # 기본 노드 수
}

# ================================================================
# 노드 의존 애드온 — 노드 그룹 생성 완료 후 설치
# ================================================================

# coredns: 클러스터 내부 DNS 서버
# 파드끼리 서비스 이름으로 통신할 때 IP를 찾아주는 역할
# (예: "javaspring" 서비스 이름 → 해당 파드 IP로 변환)
resource "aws_eks_addon" "coredns" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE" # 기존 설정과 충돌 시 덮어쓰기
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.eks_managed_node_groups] # 노드 그룹 생성 후 설치
}

# aws-ebs-csi-driver: EBS 볼륨(영구 저장소)을 파드에 마운트할 때 사용
# StatefulSet(데이터베이스 등)에서 데이터를 영구 보존하기 위해 필요
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.irsa-ebs-csi.iam_role_arn # EBS 접근 IAM 역할 연결

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.eks_managed_node_groups]
}

# AWS 관리형 EBS CSI 정책 — EBS 볼륨 생성·삭제·연결 권한 포함
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ================================================================
# IRSA(IAM Roles for Service Accounts) — EBS CSI 드라이버용
#
# IRSA란?
#   Kubernetes 파드가 AWS 서비스에 접근할 때
#   액세스 키 없이 IAM 역할의 임시 자격증명을 자동 발급받는 방식
#
#   동작 원리:
#   1. OIDC 공급자(클러스터 신원 증명 기관)가 서비스 계정에 토큰 발급
#   2. AWS STS가 토큰을 검증하고 IAM 역할의 임시 키 발급
#   3. 파드가 임시 키로 EBS, DynamoDB 등 AWS 서비스에 안전하게 접근
# ================================================================
module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.20"

  create_role = true
  role_name   = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"

  # 클러스터 OIDC 발급자 URL — 이 클러스터의 서비스 계정만 역할을 위임받을 수 있도록 제한
  provider_url     = module.eks.oidc_provider
  role_policy_arns = [data.aws_iam_policy.ebs_csi_policy.arn]

  # 이 역할을 사용할 수 있는 Kubernetes 서비스 계정 지정
  # 형식: system:serviceaccount:<네임스페이스>:<서비스계정명>
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

# ================================================================
# ArgoCD 설치 — Helm 차트로 배포
#
# ArgoCD란?
#   Git 저장소를 지속적으로 감시하다가
#   코드 변경이 감지되면 자동으로 Kubernetes에 배포해주는 GitOps 도구
#
#   흐름: CodeBuild가 deployment.yaml 이미지 태그 업데이트
#         → ArgoCD가 변경 감지 → EKS 클러스터에 자동 배포
# ================================================================
resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = "argocd"
  chart      = "argo-cd"
  repository = "https://argoproj.github.io/argo-helm"
  version    = "9.0.5"

  create_namespace = true # argocd 네임스페이스가 없으면 자동 생성

  # argocd-values.yaml: ArgoCD 커스텀 설정 (서비스 타입, 로그인 방식 등)
  values = [
    file("${path.module}/argocd-values.yaml")
  ]

  depends_on = [module.eks_managed_node_groups]
}

# ================================================================
# ArgoCD ↔ CodeCommit SSH 인증 자동 설정
#
# ArgoCD가 javaspring-apps 저장소를 읽으려면 인증이 필요
# SSH 방식: 공개키를 AWS IAM에 등록 → 개인키를 ArgoCD Secret에 저장
# ================================================================

# RSA 4096비트 SSH 키 쌍 자동 생성
# 공개키(public key): AWS IAM에 등록 → CodeCommit 인증에 사용
# 개인키(private key): ArgoCD Secret에 저장 → Git clone 시 사용
# ⚠️ 주의: 개인키가 terraform.tfstate 파일에 평문으로 저장됨
#           실무에서는 S3 암호화 백엔드 또는 HashiCorp Vault 사용 권장
resource "tls_private_key" "argocd_codecommit" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# ArgoCD 전용 IAM 유저 생성
# CodeCommit 저장소에만 접근 가능하도록 최소 권한 원칙 적용
resource "aws_iam_user" "argocd" {
  name = "argocd-codecommit-${local.cluster_name}"
  tags = local.tags
}

# ArgoCD IAM 유저에 CodeCommit 읽기 전용 정책 부여
# AWSCodeCommitReadOnly: Git pull, 저장소 조회만 허용 (push 불가)
resource "aws_iam_user_policy_attachment" "argocd_codecommit" {
  user       = aws_iam_user.argocd.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeCommitReadOnly"
}

# 생성한 SSH 공개키를 IAM 유저에 등록
# 등록 후 발급되는 ssh_public_key_id가 CodeCommit SSH URL의 username 역할
resource "aws_iam_user_ssh_key" "argocd" {
  username   = aws_iam_user.argocd.name
  encoding   = "SSH"
  public_key = tls_private_key.argocd_codecommit.public_key_openssh
}

# ArgoCD 레포지토리 인증 Secret
# argocd.argoproj.io/secret-type=repository 레이블 → ArgoCD가 자동으로 저장소 인증에 사용
resource "kubernetes_secret_v1" "argocd_repo_javaspring_apps" {
  metadata {
    name      = "codecommit-javaspring-apps"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type = "git"

    # CodeCommit SSH URL 형식:
    # ssh://<SSH공개키ID>@git-codecommit.<리전>.amazonaws.com/v1/repos/<저장소명>
    # SSH 공개키 ID = IAM에 등록한 공개키의 식별자 (username 역할)
    url           = "ssh://${aws_iam_user_ssh_key.argocd.ssh_public_key_id}@git-codecommit.${var.aws_region}.amazonaws.com/v1/repos/javaspring-apps"
    sshPrivateKey = tls_private_key.argocd_codecommit.private_key_pem
  }

  depends_on = [helm_release.argocd]
}

# ================================================================
# ArgoCD Application 리소스 — GitOps 자동 배포 설정
#
# 이 리소스가 하는 일:
#   "javaspring-apps CodeCommit 저장소를 감시하다가
#    변경이 생기면 javaspring-app 네임스페이스에 자동 배포하라"
# ================================================================
resource "kubectl_manifest" "argocd_application" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "javaspring-app"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        # 감시할 Git 저장소 URL (SSH 방식)
        repoURL        = "ssh://${aws_iam_user_ssh_key.argocd.ssh_public_key_id}@git-codecommit.${var.aws_region}.amazonaws.com/v1/repos/javaspring-apps"
        targetRevision = "main"  # main 브랜치 감시
        path           = "."     # 저장소 루트 디렉터리의 모든 YAML 파일 배포
      }
      destination = {
        server    = "https://kubernetes.default.svc" # 현재 클러스터에 배포
        namespace = "javaspring-app"                 # 배포 대상 네임스페이스
      }
      syncPolicy = {
        automated = {
          # prune: Git에서 삭제된 리소스를 클러스터에서도 자동 삭제
          prune    = true
          # selfHeal: 누군가 클러스터를 직접 수정해도 Git 상태로 자동 복구
          selfHeal = true
        }
        # CreateNamespace: javaspring-app 네임스페이스가 없으면 자동 생성
        syncOptions = ["CreateNamespace=true"]
      }
    }
  })

  depends_on = [kubernetes_secret_v1.argocd_repo_javaspring_apps]
}
