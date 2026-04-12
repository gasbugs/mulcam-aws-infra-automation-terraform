# source from: https://github.com/terraform-aws-modules/terraform-aws-eks/tree/master/examples/karpenter
#
# Karpenter란?
# EKS 클러스터에서 파드 수요에 따라 EC2 노드를 자동으로 추가/제거하는 오토스케일러
# Cluster Autoscaler와 달리 노드 그룹(ASG) 없이도 직접 EC2를 프로비저닝하여 더 빠르고 유연함
# 구조:
#   시스템 노드 그룹(고정) ──► Karpenter 파드, EKS Addon 실행
#   Karpenter가 관리하는 노드(동적) ──► 애플리케이션 파드 실행 (수요에 따라 자동 생성/삭제)
#
# 추가 기능: EBS(블록 스토리지), EFS(공유 파일 스토리지), S3 IRSA 접근 실습 포함

resource "random_integer" "random_id" {
  max = 9999
  min = 1000
}

# 사용 가능한 가용 영역(AZ) 조회 — Local Zone 제외
# opt-in-not-required: 별도 활성화 없이 기본 사용 가능한 AZ만 선택 (Local Zone은 제외)
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = "karpenter-cluster-${random_integer.random_id.result}"
  tags = {
    Environment   = "prod"
    Team          = "platform-team"
    Application   = "web-app"
    CostCenter    = "CC-1234"
    ProvisionedBy = "Karpenter"
    Region        = "us-east-1"
  }
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
}

################################################################################
# EKS Module
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.8.0" # 버전 핀 추가 (재현 가능한 빌드를 위해 항상 버전 고정 권장)

  name               = local.name
  kubernetes_version = "1.35" # 최신 안정 버전으로 업데이트

  # Gives Terraform identity admin access to cluster which will
  # allow deploying resources (Karpenter) into the cluster
  enable_cluster_creator_admin_permissions = true
  endpoint_public_access                   = true

  # DaemonSet 기반 애드온만 모듈 내에서 설치 (노드 없이도 ACTIVE 전환)
  # coredns, aws-ebs-csi-driver, aws-efs-csi-driver는 Deployment 기반이므로
  # 노드그룹 생성 이후에 별도 리소스로 설치
  addons = {
    eks-pod-identity-agent = {} # EKS Pod Identity 에이전트 (DaemonSet)
    kube-proxy             = {} # 노드 간 네트워크 규칙 관리 (DaemonSet)
    vpc-cni                = {} # 노드 네트워크에 반드시 필요한 CNI 플러그인 (DaemonSet)
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  # cluster_tags = merge(local.tags, {
  #   NOTE - only use this option if you are using "attach_cluster_primary_security_group"
  #   and you know what you're doing. In this case, you can remove the "node_security_group_tags" below.
  #  "karpenter.sh/discovery" = local.name
  # })

  # Karpenter가 사용할 노드 보안 그룹을 식별하는 태그
  # Karpenter는 이 태그를 보고 새 노드에 적용할 보안 그룹을 자동으로 찾음
  # 주의: 계정 내에 동일 태그를 가진 보안 그룹이 여러 개이면 혼선이 생기므로 반드시 하나만 태깅
  node_security_group_tags = merge(local.tags, {
    "karpenter.sh/discovery" = "karpenter-cluster-${random_integer.random_id.result}"
  })

  tags = local.tags
}


################################################################################
# 노드 그룹 — module.eks 완료 후 생성 (DaemonSet 애드온 설치 후 노드 기동)
# Karpenter가 관리하는 노드와 달리, 이 노드 그룹은 EKS Addon과 Karpenter 자체를 실행
################################################################################

# 노드 그룹용 IAM 역할 — EC2가 EKS 워커 노드로 동작하기 위해 필요한 4가지 정책 부여
# 1) AmazonEKSWorkerNodePolicy     : EKS API 서버와 통신 (노드 등록/하트비트)
# 2) AmazonEKS_CNI_Policy          : VPC CNI 플러그인이 파드에 IP를 할당하는 권한
# 3) AmazonEC2ContainerRegistryReadOnly : ECR에서 컨테이너 이미지를 pull하는 권한
# 4) AmazonSSMManagedInstanceCore  : SSM Session Manager로 노드에 접근하는 권한 (키페어 없이 SSH 대체)
resource "aws_iam_role" "node_group" {
  name = "eks-node-group-role-${local.name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "node_group_worker" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_group_cni" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_group_ecr" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_group_ssm" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # SSM 접근 허용
}

# Karpenter 시스템 노드 그룹용 런치 템플릿 — IMDS hop limit 2 설정
# Karpenter 파드가 EC2 메타데이터 서비스(IMDS)를 통해 리전 정보를 가져오려면
# hop limit이 최소 2 이상이어야 함 (기본값 1이면 컨테이너에서 401 오류 발생)
resource "aws_launch_template" "karpenter_system" {
  name_prefix = "karpenter-system-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"        # IMDSv2 강제
    http_put_response_hop_limit = 2                 # 파드 → 노드 → IMDS 2홉 허용
  }
}

# Karpenter와 EKS Addon을 실행하기 위한 관리형 노드 그룹
# CriticalAddonsOnly taint를 추가하여 Karpenter가 관리하는 Pod만 이 노드에서 실행되도록 제한
resource "aws_eks_node_group" "karpenter" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "karpenter"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = module.vpc.private_subnets

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = ["m5.large"]

  launch_template {
    id      = aws_launch_template.karpenter_system.id
    version = aws_launch_template.karpenter_system.latest_version
  }

  scaling_config {
    min_size     = 2
    max_size     = 3
    desired_size = 2
  }

  taint {
    # EKS Addon과 Karpenter만 이 노드에서 실행되도록 taint 설정
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = {
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.node_group_worker,
    aws_iam_role_policy_attachment.node_group_cni,
    aws_iam_role_policy_attachment.node_group_ecr,
    aws_iam_role_policy_attachment.node_group_ssm,
    module.eks,
  ]
}

# -----------------------------------------------------------------------
# 노드 의존 애드온 — 노드그룹 생성 완료 후 설치
# Deployment 기반이라 노드가 있어야 pod가 스케줄되어 ACTIVE 전환
# -----------------------------------------------------------------------

# 클러스터 내부 DNS 서비스 (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "coredns" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.karpenter]
}

# EBS 볼륨을 Kubernetes PV로 사용하기 위한 드라이버 (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = module.irsa-ebs-csi.iam_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.karpenter]
}

# EFS 볼륨을 Kubernetes PV로 사용하기 위한 드라이버 (Deployment 기반 → 노드 필요)
resource "aws_eks_addon" "efs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-efs-csi-driver"
  service_account_role_arn    = module.irsa-efs-csi.iam_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.karpenter]
}

################################################################################
# Karpenter
################################################################################

# Karpenter 모듈: SQS 중단 큐, Node IAM 역할, Pod Identity 연결 등 Karpenter 동작에
# 필요한 AWS 리소스를 한 번에 생성해주는 서브모듈
# - SQS 큐: EC2 Spot 중단·재균형 이벤트를 수신하여 Karpenter가 미리 대응하도록 함
# - Node IAM 역할: Karpenter가 프로비저닝한 새 노드들이 사용할 IAM 역할
# - Pod Identity: Karpenter 파드(서비스 계정)가 IAM 역할의 권한으로 EC2를 생성/삭제할 수 있도록 연결
module "karpenter" {
  source = "./.terraform/modules/eks/modules/karpenter"

  cluster_name = local.name

  # create_pod_identity_association = true:
  # Karpenter 서비스 계정 → IAM 역할 자동 연결 (IRSA 방식 대신 Pod Identity 방식 사용)
  create_pod_identity_association = true

  # Karpenter가 생성하는 노드의 IAM 역할에 SSM 정책 추가 (SSH 키 없이 노드 접근 가능)
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

# # 카펜터를 disable하는 예제 
# module "karpenter_disabled" {
#   source = "./.terraform/modules/eks/modules/karpenter"

#   create = false
# }

################################################################################
# Karpenter Helm chart & manifests
# Not required; just to demonstrate functionality of the sub-module
################################################################################

# Karpenter Helm 차트 설치 — kube-system 네임스페이스에 Karpenter 컨트롤러 배포
# Helm values로 클러스터 이름·엔드포인트·SQS 큐 이름을 주입하여 Karpenter가 올바른 클러스터를 관리하도록 설정
resource "helm_release" "karpenter" {
  namespace  = "kube-system"
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.0.6"
  wait       = false  # 파드가 Ready 상태가 될 때까지 기다리지 않음 (NodeClass/NodePool 생성이 먼저이므로)

  values = [
    <<-EOT
    serviceAccount:
      name: ${module.karpenter.service_account}  # Pod Identity와 연결된 서비스 계정 이름
    settings:
      clusterName: ${module.eks.cluster_name}         # Karpenter가 관리할 EKS 클러스터 이름
      clusterEndpoint: ${module.eks.cluster_endpoint} # EKS API 서버 엔드포인트
      interruptionQueue: ${module.karpenter.queue_name} # Spot 중단 이벤트 수신용 SQS 큐 이름
    EOT
  ]
}


# AWS SSM Parameter Store에서 EKS 최적화 AMI ID 조회
# SSM Parameter Store: AWS가 공식적으로 제공하는 파라미터 저장소
# kubernetes_version(1.35)에 맞는 최신 AL2023 AMI ID를 자동으로 가져옴
# → Karpenter NodeClass에서 이 AMI로 새 노드를 프로비저닝함
data "aws_ssm_parameter" "eks_ami" {
  name = "/aws/service/eks/optimized-ami/1.35/amazon-linux-2023/x86_64/standard/recommended/image_id"
}

# NodeClass: Karpenter가 새 노드를 만들 때 사용할 EC2 설정 템플릿
# → AMI ID, 서브넷, 보안 그룹, IAM 인스턴스 프로파일 등 노드의 기본 스펙을 정의
# nodeclasses.yaml 파일에 변수(AMI ID, 클러스터 이름 등)를 주입하여 배포
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = templatefile("${path.module}/nodeclasses.yaml",
    {
      node_iam_role_name = module.karpenter.node_iam_role_name  # 노드에 부여할 IAM 역할 이름
      cluster_name       = module.eks.cluster_name              # 클러스터 태그 자동 발견에 사용
      ami_id             = data.aws_ssm_parameter.eks_ami.value # SSM에서 조회한 최신 AL2023 AMI ID
    }
  )

  depends_on = [
    helm_release.karpenter  # Karpenter가 먼저 실행 중이어야 CRD를 인식할 수 있음
  ]
}

# NodePool: Karpenter가 파드 수요에 따라 노드를 프로비저닝할 때 적용할 정책 정의
# → 허용할 인스턴스 유형, 구매 옵션(On-Demand/Spot), CPU/메모리 한도, 만료 기간 등 설정
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = file("${path.module}/nodepool.yaml")

  depends_on = [
    kubectl_manifest.karpenter_node_class  # NodeClass가 먼저 존재해야 NodePool이 참조 가능
  ]
}


################################################################################
# Supporting Resources
################################################################################

# VPC 생성 — EKS 클러스터와 Karpenter 노드가 사용할 네트워크 환경
# 서브넷 구성:
#   private_subnets: 워커 노드와 파드가 배치되는 프라이빗 서브넷 (인터넷 직접 노출 없음)
#   public_subnets : NAT 게이트웨이, 로드밸런서(ALB)가 위치하는 퍼블릭 서브넷
#   intra_subnets  : EKS 컨트롤 플레인 ENI 전용 서브넷 (외부 라우팅 없는 완전 격리 서브넷)
#                    컨트롤 플레인과 워커 노드 간 통신만 허용하여 보안 강화
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 52)]

  enable_nat_gateway = true  # 프라이빗 서브넷에서 인터넷 아웃바운드 허용 (ECR pull, OS 업데이트 등)
  single_nat_gateway = true  # NAT 게이트웨이 1개 공유 (비용 절감, 가용성보다 비용 우선)

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1  # ALB Ingress Controller가 퍼블릭 서브넷을 자동 감지하는 태그
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1           # 내부 로드밸런서용 프라이빗 서브넷 태그
    "karpenter.sh/discovery" = local.name            # Karpenter가 노드를 배치할 서브넷 자동 감지 태그
  }

  tags = local.tags
}



################################################################################
# IRSA 모듈 정의 — EBS·EFS CSI 드라이버용 IAM 역할
# IRSA(IAM Roles for Service Accounts): 파드가 AWS 서비스에 접근할 때
# 영구 자격증명(액세스 키) 없이 IAM 역할의 임시 자격증명을 자동으로 발급받는 방식
# 원리: OIDC(클러스터 신원 발급자) → 서비스 계정(파드 신원) → IAM 역할(AWS 권한)
################################################################################
# EBS CSI 드라이버 IRSA — ebs-csi-controller-sa 서비스 계정이 EBS 볼륨을 조작하는 권한
module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.20"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider  # 클러스터 OIDC 발급자 URL
  role_policy_arns              = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
  # 이 역할을 맡을 수 있는 Kubernetes 서비스 계정을 네임스페이스:이름 형식으로 지정
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

# EFS CSI 드라이버 IRSA — efs-csi-controller-sa 서비스 계정이 EFS 파일 시스템을 마운트하는 권한
module "irsa-efs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.20"

  create_role                   = true
  role_name                     = "AmazonEKSEFSRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider  # 클러스터 OIDC 발급자 URL
  role_policy_arns              = ["arn:aws:iam::aws:policy/AmazonElasticFileSystemFullAccess"]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:efs-csi-controller-sa"]
}

# EFS(Elastic File System) 파일 시스템 생성
# EFS: 여러 파드·노드가 동시에 읽고 쓸 수 있는 공유 파일 스토리지 (NFS 기반)
# EBS는 한 노드에만 붙는 반면, EFS는 여러 가용 영역의 파드에서 동시 마운트 가능
resource "aws_efs_file_system" "example" {
  creation_token = "efs-example"
  encrypted      = true  # 저장 데이터 암호화 (KMS 기본 키 사용)
  tags = {
    Name = "example-efs"
  }
}

# 출력할 EFS 파일 시스템 ID
output "efs_file_system_id" {
  value = aws_efs_file_system.example.id
}


# EFS 보안 그룹 생성
resource "aws_security_group" "my_efs_sg" {
  name        = "efs-sg"
  description = "Allow NFS traffic for EFS"
  vpc_id      = module.vpc.vpc_id # VPC ID를 VPC 모듈에서 가져옴

  # 인바운드 규칙: NFS 트래픽 (포트 2049) 허용
  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # VPC 내 트래픽을 허용 (필요시 변경)
  }

  # 아웃바운드 규칙: 모든 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "efs-sg"
  }
}


# 각 서브넷(가용 영역)에 대해 EFS 마운트 타겟 생성
# count 방식 사용 — for_each는 apply-time 서브넷 ID를 키로 쓸 수 없어 plan 단계 오류 발생
resource "aws_efs_mount_target" "example" {
  count           = length(module.vpc.private_subnets) # 프라이빗 서브넷 수만큼 반복
  file_system_id  = aws_efs_file_system.example.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.my_efs_sg.id]
}
