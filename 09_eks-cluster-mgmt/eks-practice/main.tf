# source from: https://github.com/terraform-aws-modules/terraform-aws-eks/tree/master/examples/karpenter
resource "random_integer" "random_id" {
  max = 9999
  min = 1000
}

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
  kubernetes_version = "1.34" # 최신 안정 버전으로 업데이트

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

  node_security_group_tags = merge(local.tags, {
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    # (i.e. - at most, only one security group should have this tag in your account)
    "karpenter.sh/discovery" = "karpenter-cluster-${random_integer.random_id.result}"
  })

  tags = local.tags
}


################################################################################
# 노드 그룹 — module.eks 완료 후 생성 (DaemonSet 애드온 설치 후 노드 기동)
# Karpenter가 관리하는 노드와 달리, 이 노드 그룹은 EKS Addon과 Karpenter 자체를 실행
################################################################################

# 노드 그룹용 IAM 역할 (EC2 인스턴스가 EKS 노드로 동작하기 위해 필요)
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

# Karpenter와 EKS Addon을 실행하기 위한 관리형 노드 그룹
# CriticalAddonsOnly taint를 추가하여 Karpenter가 관리하는 Pod만 이 노드에서 실행되도록 제한
resource "aws_eks_node_group" "karpenter" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "karpenter"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = module.vpc.private_subnets

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = ["m5.large"]

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

module "karpenter" {
  source = "./.terraform/modules/eks/modules/karpenter"

  cluster_name = local.name

  # Pod Identity 연결 자동 생성 (Karpenter 서비스 계정 → IAM 역할 연결)
  create_pod_identity_association = true

  # Karpenter가 관리하는 노드의 IAM 역할에 추가 정책 부여
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

resource "helm_release" "karpenter" {
  namespace  = "kube-system"
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  #repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  #repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart   = "karpenter"
  version = "1.0.6"
  wait    = false

  values = [
    <<-EOT
    serviceAccount:
      name: ${module.karpenter.service_account}
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    EOT
  ]
}


# EKS에서 추천되는 AMI 검색 
data "aws_ssm_parameter" "eks_ami" {
  # kubernetes_version과 동일한 버전의 EKS 최적화 AMI ID를 SSM Parameter Store에서 동적으로 조회
  name = "/aws/service/eks/optimized-ami/1.34/amazon-linux-2023/x86_64/standard/recommended/image_id"
}

resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = templatefile("${path.module}/nodeclasses.yaml",
    {
      node_iam_role_name = module.karpenter.node_iam_role_name
      cluster_name       = module.eks.cluster_name
      ami_id             = data.aws_ssm_parameter.eks_ami.value
    }
  )

  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = file("${path.module}/nodepool.yaml")

  depends_on = [
    kubectl_manifest.karpenter_node_class
  ]
}


################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 52)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Tags subnets for Karpenter auto-discovery
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}



################################################################################
# IRSA 모듈 정의 (EBS CSI 드라이버)
################################################################################
module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.20"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

module "irsa-efs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.20"

  create_role                   = true
  role_name                     = "AmazonEKSEFSRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = ["arn:aws:iam::aws:policy/AmazonElasticFileSystemFullAccess"] # EFS에 대한 전체 액세스 권한 부여
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:efs-csi-controller-sa"]
}

# EFS 파일 시스템 생성
resource "aws_efs_file_system" "example" {
  creation_token = "efs-example"
  encrypted      = true # 암호화 여부
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
resource "aws_efs_mount_target" "example" {
  for_each        = toset(module.vpc.private_subnets) # 모든 프라이빗 서브넷에 대해 반복
  file_system_id  = aws_efs_file_system.example.id
  subnet_id       = each.value
  security_groups = [aws_security_group.my_efs_sg.id]

  depends_on = [module.vpc.private_subnets]
}
