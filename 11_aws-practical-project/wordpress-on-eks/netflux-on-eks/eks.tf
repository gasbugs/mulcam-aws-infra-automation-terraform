# EKS 클러스터 생성 모듈을 정의. Terraform의 EKS 모듈을 사용
module "eks" {
  source  = "terraform-aws-modules/eks/aws" # EKS 모듈의 소스 경로
  version = "21.8"                          # EKS 모듈의 버전

  # 클러스터 이름과 버전 설정
  name               = local.cluster_name # 로컬에서 정의한 클러스터 이름 사용
  kubernetes_version = "1.33"             # EKS 클러스터의 버전 설정

  endpoint_public_access                   = true # 클러스터의 퍼블릭 엔드포인트 접근을 허용
  enable_cluster_creator_admin_permissions = true # 클러스터 생성자에게 관리 권한 부여

  # 클러스터 추가 기능 설정 (EBS CSI 드라이버)
  addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.irsa-ebs-csi.iam_role_arn # IRSA로 연동된 역할의 ARN 사용
    }
  }

  vpc_id     = module.vpc.vpc_id          # 생성된 VPC ID 사용
  subnet_ids = module.vpc.private_subnets # 생성된 사설 서브넷 사용

  # EKS 관리형 노드 그룹 정의
  eks_managed_node_groups = {
    on_demand = {
      name           = "on_demand"              # 첫 번째 노드 그룹 이름
      ami_type       = "AL2023_x86_64_STANDARD" # Amazon Linux 2023 사용
      instance_types = ["c5.large"]             # 노드 인스턴스 유형

      min_size     = 1 # 최소 노드 수
      max_size     = 3 # 최대 노드 수
      desired_size = 2 # 원하는 노드 수
    }
  }
}

##############################################################
# IRSA(Identity and Access Management Roles for Service Accounts) 모듈을 정의
# EBS CSI 드라이버 정책을 불러옴
# EKS 클러스터에서 사용될 EBS CSI 드라이버 IAM 정책 정의
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# EKS 클러스터에 EBS CSI 드라이버와 연동할 역할을 생성
module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc" # IAM 모듈의 경로
  version = "4.20"                                                                # 모듈 버전

  create_role                   = true                                                        # 역할을 생성하도록 설정
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"          # 역할 이름 설정
  provider_url                  = module.eks.oidc_provider                                    # EKS OIDC 프로바이더 URL
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]                    # EBS CSI 드라이버 정책 ARN
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"] # OIDC 주체 설정
}

# EKS 클러스터에 dynamodb와 연동할 역할을 생성
data "aws_iam_policy" "dynamodb_policy" {
  arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

module "dynamodb_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc" # IAM 모듈의 경로
  version = "4.20"

  create_role                   = true # 역할을 생성하도록 설정
  role_name                     = "eks-dynamodb-access-${random_integer.unique_id.result}"
  provider_url                  = module.eks.oidc_provider # EKS OIDC 프로바이더 URL
  role_policy_arns              = [data.aws_iam_policy.dynamodb_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:netflux:netflux-sa"] # OIDC 주체 설정
}

# 서비스 계정 생성
resource "kubernetes_service_account" "netflux_sa" {
  metadata {
    name      = "netflux-sa"
    namespace = kubernetes_namespace.netflux.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = module.dynamodb_irsa_role.iam_role_arn
    }
  }
  depends_on = [kubernetes_service.netflux_svc]
}


##############################################################
# ArgoCD 설치
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

  depends_on = [null_resource.eks_kubectl_config]
}
