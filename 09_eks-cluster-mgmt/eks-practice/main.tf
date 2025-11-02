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
  source = "terraform-aws-modules/eks/aws"

  name               = local.name
  kubernetes_version = "1.33"

  # Gives Terraform identity admin access to cluster which will
  # allow deploying resources (Karpenter) into the cluster
  enable_cluster_creator_admin_permissions = true
  endpoint_public_access                   = true

  addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}

    # Amazon EBS CSI Driver
    aws-ebs-csi-driver = {
      #version                  = "v1.3.0"
      update_policy            = "OVERWRITE"
      service_account_role_arn = module.irsa-ebs-csi.iam_role_arn # IRSA 역할 추가
    }

    # Amazon EFS CSI Driver
    aws-efs-csi-driver = {
      update_policy            = "OVERWRITE"
      service_account_role_arn = module.irsa-efs-csi.iam_role_arn # IRSA 역할 추가
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  eks_managed_node_groups = {
    karpenter = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["m5.large"]

      min_size     = 2
      max_size     = 3
      desired_size = 2

      taints = {
        # This Taint aims to keep just EKS Addons and Karpenter running on this MNG
        # The pods that do not tolerate this taint should run on nodes created by Karpenter
        addons = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

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
# Karpenter
################################################################################

module "karpenter" {
  source = "./.terraform/modules/eks/modules/karpenter"

  cluster_name                    = local.name
  enable_v1_permissions           = true
  enable_pod_identity             = true
  create_pod_identity_association = true

  # Used to attach additional IAM policies to the Karpenter node IAM role
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
  name = "/aws/service/eks/optimized-ami/1.31/amazon-linux-2023/x86_64/standard/recommended/image_id"
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
