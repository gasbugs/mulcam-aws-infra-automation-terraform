# EKS 클러스터 생성 모듈
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.8"

  name               = local.cluster_name
  kubernetes_version = "1.34"

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
    }
    coredns    = {}
    kube-proxy = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    vpc-cni = {
      before_compute = true
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

data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.20"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
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

# RSA 4096비트 SSH 키 쌍 자동 생성
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
resource "kubernetes_secret_v1" "argocd_repo_flask_example_apps" {
  metadata {
    name      = "codecommit-flask-example-apps"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type          = "git"
    url           = "ssh://${aws_iam_user_ssh_key.argocd.ssh_public_key_id}@git-codecommit.${var.aws_region}.amazonaws.com/v1/repos/flask-example-apps"
    sshPrivateKey = tls_private_key.argocd_codecommit.private_key_pem
  }

  depends_on = [helm_release.argocd]
}

# ArgoCD Application 리소스 — flask-example-apps 저장소와 EKS 클러스터를 연결
resource "kubernetes_manifest" "argocd_application" {
  manifest = {
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
        path           = "."
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "flask-app"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }

  depends_on = [kubernetes_secret_v1.argocd_repo_flask_example_apps]
}
