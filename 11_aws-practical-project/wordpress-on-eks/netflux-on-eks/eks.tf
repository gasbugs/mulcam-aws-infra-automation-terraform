##############################################################
# EKS 클러스터 모듈 정의
# 중요: addons 블록에는 DaemonSet 기반 애드온만 포함
# Deployment 기반 애드온(coredns, aws-ebs-csi-driver)은 노드 그룹 생성 후 별도 리소스로 분리
module "eks" {
  source  = "terraform-aws-modules/eks/aws" # EKS 모듈의 소스 경로
  version = "21.8"                          # EKS 모듈의 버전

  # 클러스터 이름과 버전 설정
  name               = local.cluster_name # 로컬에서 정의한 클러스터 이름 사용
  kubernetes_version = "1.32"             # AWS EKS 지원 안정 버전 (LTS)

  endpoint_public_access                   = true # 클러스터의 퍼블릭 엔드포인트 접근을 허용
  enable_cluster_creator_admin_permissions = true # 클러스터 생성자에게 관리 권한 부여

  # DaemonSet 기반 애드온만 여기에 포함 — 노드 없이도 ACTIVE 상태로 전환 가능
  # coredns와 aws-ebs-csi-driver는 아래 aws_eks_addon 리소스로 별도 관리
  addons = {
    kube-proxy = {} # 노드 간 네트워크 규칙 관리용 DaemonSet
    eks-pod-identity-agent = {
      before_compute = true # 노드 생성 전에 먼저 설치해야 하는 DaemonSet 애드온
    }
    vpc-cni = {
      before_compute = true # 파드에 VPC IP를 직접 할당하는 DaemonSet, 노드보다 먼저 설치 필요
    }
  }

  vpc_id     = module.vpc.vpc_id          # 생성된 VPC ID 사용
  subnet_ids = module.vpc.private_subnets # 생성된 사설 서브넷 사용
}

##############################################################
# EKS 관리형 노드 그룹 — EKS 모듈과 분리하여 별도 배포
# 이유: 노드 그룹은 클러스터 생성 후 독립적으로 관리하는 것이 모범사례
module "eks_managed_node_groups" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group" # EKS 관리형 노드 그룹 모듈 경로
  version = "21.8"                                                           # 모듈 버전

  name                 = "on_demand"                     # 노드 그룹 이름
  cluster_name         = module.eks.cluster_name         # EKS 클러스터 이름
  cluster_service_cidr = module.eks.cluster_service_cidr # 클러스터 서비스 CIDR
  subnet_ids           = module.vpc.private_subnets      # 사설 서브넷 ID

  kubernetes_version = "1.32"                # 클러스터와 동일한 버전으로 명시 (미지정 시 최신 버전 AMI를 선택해 버전 불일치 오류 발생)
  ami_type           = "AL2023_x86_64_STANDARD" # Amazon Linux 2023 사용
  instance_types     = ["c5.large"]             # 노드 인스턴스 유형
  min_size       = 1                        # 최소 노드 수
  max_size       = 3                        # 최대 노드 수
  desired_size   = 2                        # 원하는 노드 수
}

##############################################################
# 노드 의존 애드온 — 노드 그룹 생성 완료 후 설치 (Deployment 기반이라 실행할 노드 필요)

# CoreDNS: 클러스터 내부 DNS 서비스 (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "coredns" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # 반드시 노드 그룹이 먼저 생성된 후 설치 (노드가 없으면 파드가 Pending 상태로 대기)
  depends_on = [module.eks_managed_node_groups]
}

# AWS EBS CSI 드라이버: 영구 볼륨(PVC) 프로비저닝 (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = module.irsa-ebs-csi.iam_role_arn # IRSA로 연동된 역할의 ARN 사용

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # 반드시 노드 그룹이 먼저 생성된 후 설치
  depends_on = [module.eks_managed_node_groups]
}


##############################################################
# IRSA(IAM Roles for Service Accounts) — EBS CSI 드라이버용
# 원리: 파드가 영구 자격증명(액세스 키) 없이 OIDC를 통해 IAM 역할의 임시 자격증명을 자동 발급받는 방식
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# EKS 클러스터에 EBS CSI 드라이버와 연동할 역할을 생성
module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc" # IAM 모듈의 경로
  version = "4.20"                                                                 # 모듈 버전

  create_role                   = true                                                        # 역할을 생성하도록 설정
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"          # 역할 이름 설정
  provider_url                  = module.eks.oidc_provider                                    # EKS OIDC 프로바이더 URL
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]                    # EBS CSI 드라이버 정책 ARN
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"] # OIDC 주체 설정
}

##############################################################
# IRSA — DynamoDB 접근용 IAM 역할
# netflux 앱 파드가 DynamoDB에 접근할 때 사용하는 임시 자격증명 역할
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

# netflux 애플리케이션이 DynamoDB에 접근할 때 사용하는 Kubernetes 서비스 계정
# annotations의 role-arn을 통해 IRSA가 자동으로 임시 자격증명을 파드에 주입
resource "kubernetes_service_account_v1" "netflux_sa" {
  metadata {
    name      = "netflux-sa"
    namespace = kubernetes_namespace_v1.netflux.metadata[0].name
    annotations = {
      # 이 어노테이션으로 Kubernetes 서비스 계정과 AWS IAM 역할을 연결 (IRSA)
      "eks.amazonaws.com/role-arn" = module.dynamodb_irsa_role.iam_role_arn
    }
  }
  # 네임스페이스가 먼저 생성된 후 서비스 계정 생성
  depends_on = [kubernetes_namespace_v1.netflux]
}


##############################################################
# ArgoCD 설치 — GitOps 방식으로 netflux 애플리케이션을 자동 배포하는 CD 도구
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

  # 노드 그룹이 준비된 후 ArgoCD 설치 (exec 방식 provider는 kubeconfig 파일 불필요)
  depends_on = [module.eks_managed_node_groups]
}
