# EKS 클러스터 생성 모듈
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.8"

  name               = local.cluster_name
  kubernetes_version = "1.35"

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  # 노드 생성 전 설치 가능한 애드온만 여기에 포함
  # Deployment 기반 애드온(coredns, aws-ebs-csi-driver)은 노드 그룹 생성 후 별도 리소스로 분리
  addons = {
    kube-proxy = {}
    eks-pod-identity-agent = {
      before_compute = true # 노드 생성 전에 먼저 설치해야 하는 애드온
    }
    vpc-cni = {
      before_compute = true # 노드 네트워크 설정을 위해 노드보다 먼저 설치
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
}

# EKS 관리형 노드 그룹 — ArgoCD와 Flask 앱이 실행될 워커 노드
module "eks_managed_node_groups" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "21.8"

  name                 = "on_demand"
  cluster_name         = module.eks.cluster_name
  cluster_service_cidr = module.eks.cluster_service_cidr
  subnet_ids           = module.vpc.private_subnets

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = ["c5.large"]
  min_size       = 1
  max_size       = 3
  desired_size   = 2
}

# 노드 의존 애드온 — 노드 그룹 생성 완료 후 설치 (Deployment 기반이라 노드 필요)
# coredns: 클러스터 내부 DNS, Deployment 기반
resource "aws_eks_addon" "coredns" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.eks_managed_node_groups]
}

# aws-ebs-csi-driver: EBS 볼륨 프로비저닝, Deployment 기반
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.irsa-ebs-csi.iam_role_arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.eks_managed_node_groups]
}

# EBS CSI 드라이버 정책 (영구 볼륨 지원)
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# IRSA(IAM Roles for Service Accounts): Kubernetes 파드가 AWS 서비스에 접근할 때
# 영구 자격증명(액세스 키) 없이 IAM 역할의 임시 자격증명을 자동으로 발급받는 방식
# 원리: OIDC(클러스터 신원 발급자) → 서비스 계정(파드 신원) → IAM 역할(AWS 권한)
# ebs-csi-controller-sa 서비스 계정이 이 역할을 맡아 EBS 볼륨 생성/삭제/연결 작업 수행
module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.20"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider  # 클러스터 OIDC 발급자 URL
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  # 이 역할을 맡을 수 있는 Kubernetes 서비스 계정을 네임스페이스:이름 형식으로 지정
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

###################################################################
# ArgoCD Helm 설치
resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = "argocd"
  chart      = "argo-cd"
  repository = "https://argoproj.github.io/argo-helm"
  version    = "9.0.5"

  create_namespace = true

  values = [
    file("${path.module}/argocd-values.yaml")
  ]

  depends_on = [module.eks_managed_node_groups]
}


###################################################################
# ArgoCD → CodeCommit SSH 인증 설정
# ArgoCD가 flask-example-apps CodeCommit 저장소를 SSH로 읽을 수 있도록 자동 설정

# RSA 4096비트 SSH 키 쌍 자동 생성 (외부 키 파일 없이 Terraform이 직접 관리)
# 주의: 생성된 개인키(private_key_pem)는 Terraform 상태 파일(terraform.tfstate)에 평문으로 저장됨
#       → 운영 환경에서는 tfstate를 암호화된 S3 원격 백엔드에 저장하거나 Vault 등을 사용 권장
resource "tls_private_key" "argocd_codecommit" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# ArgoCD 전용 IAM 유저 (CodeCommit 읽기 전용 권한만 부여)
resource "aws_iam_user" "argocd" {
  name = "argocd-codecommit-${local.cluster_name}"
  tags = local.tags
}

resource "aws_iam_user_policy_attachment" "argocd_codecommit" {
  user       = aws_iam_user.argocd.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeCommitReadOnly"
}

# 생성된 SSH 공개키를 IAM 유저에 등록
resource "aws_iam_user_ssh_key" "argocd" {
  username   = aws_iam_user.argocd.name
  encoding   = "SSH"
  public_key = tls_private_key.argocd_codecommit.public_key_openssh
}

# ArgoCD 레포지토리 시크릿 — SSH 개인키 + CodeCommit URL 저장
# argocd.argoproj.io/secret-type=repository 레이블로 ArgoCD가 자동 인식하여 저장소 인증 정보로 사용
resource "kubernetes_secret_v1" "argocd_repo_flask_example_apps" {
  metadata {
    name      = "codecommit-flask-example-apps"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository" # ArgoCD가 이 시크릿을 저장소 인증 정보로 인식
    }
  }

  data = {
    type = "git"
    # CodeCommit SSH URL 형식: ssh://<SSH공개키ID>@git-codecommit.<리전>.amazonaws.com/v1/repos/<저장소명>
    # SSH 공개키 ID(ssh_public_key_id)가 일반 SSH URL의 username 역할을 함
    url           = "ssh://${aws_iam_user_ssh_key.argocd.ssh_public_key_id}@git-codecommit.${var.aws_region}.amazonaws.com/v1/repos/flask-example-apps"
    sshPrivateKey = tls_private_key.argocd_codecommit.private_key_pem  # 인증에 사용할 개인키
  }

  depends_on = [helm_release.argocd]
}

# ArgoCD Application 리소스 — flask-example-apps 저장소와 EKS 클러스터를 연결
# kubectl_manifest 사용: kubernetes_manifest는 plan 단계에서 클러스터 연결을 시도해
# 클러스터가 없을 때 apply 자체가 실패하는 문제가 있음 → kubectl_manifest로 대체
resource "kubectl_manifest" "argocd_application" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "flask-app"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "ssh://${aws_iam_user_ssh_key.argocd.ssh_public_key_id}@git-codecommit.${var.aws_region}.amazonaws.com/v1/repos/flask-example-apps"
        targetRevision = "main"
        path           = "flask-example-deploy"  # flask-example-apps 레포 내 K8s 매니페스트 디렉토리
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "flask-app"
      }
      syncPolicy = {
        automated = {
          prune    = true  # Git에서 삭제된 리소스를 클러스터에서도 자동 삭제
          selfHeal = true  # 클러스터 상태가 Git과 달라지면 자동으로 Git 상태로 되돌림
        }
        syncOptions = ["CreateNamespace=true"]  # 대상 네임스페이스(flask-app)가 없으면 자동 생성
      }
    }
  })

  depends_on = [kubernetes_secret_v1.argocd_repo_flask_example_apps]
}
