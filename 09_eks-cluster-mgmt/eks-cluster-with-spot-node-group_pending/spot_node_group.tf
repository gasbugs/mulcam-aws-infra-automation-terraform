
# -----------------------------------------------------------------------
# ON_DEMAND 노드 그룹 — 안정성이 필요한 시스템 컴포넌트(coredns 등) 실행
# capacity_type = "ON_DEMAND" : 인터럽트 없이 안정적으로 실행되는 일반 인스턴스
# -----------------------------------------------------------------------
resource "aws_eks_node_group" "on_demand_nodegroup" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "on-demand-ng"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = module.vpc.private_subnets

  scaling_config {
    desired_size = 1
    max_size     = 4
    min_size     = 1
  }

  instance_types = ["c5.large"]
  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND" # 일반 온디맨드 인스턴스 (인터럽트 없음)

  # eks.amazonaws.com/capacityType 레이블로 ON_DEMAND / SPOT 구분 가능
  labels = {
    type = "on-demand"
  }

  tags = {
    Name = "eks-on-demand-ng"
  }

  # IAM 역할 정책 연결 완료 후 노드 그룹 생성
  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.ecr_readonly_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
  ]
}

# -----------------------------------------------------------------------
# SPOT 노드 그룹 — 비용 절감을 위한 스팟 인스턴스 노드 그룹
# capacity_type = "SPOT" : AWS 여유 용량을 저렴하게 사용하지만 인터럽트 가능
# -----------------------------------------------------------------------
resource "aws_eks_node_group" "spot_nodegroup" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "spot-ng"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = module.vpc.private_subnets

  scaling_config {
    desired_size = 2
    max_size     = 8
    min_size     = 2
  }

  instance_types = ["m5.large"]
  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "SPOT"

  labels = {
    type = "spot"
  }

  tags = {
    Name = "eks-spot-ng"
  }

  # IAM 역할 정책 연결 완료 후 노드 그룹 생성
  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.ecr_readonly_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
  ]
}

# -----------------------------------------------------------------------
# ON_DEMAND / SPOT 노드 그룹이 공유하는 IAM 역할
# EC2 인스턴스가 EKS 노드로 동작하기 위해 필요한 역할
# -----------------------------------------------------------------------
# 노드 그룹에 구성할 role 작성
# IAM 역할 이름은 계정 전역 고유해야 하므로 클러스터 이름을 붙여 중복 방지
resource "aws_iam_role" "eks_node_role" {
  name = "eks-node-group-role-${module.eks.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "eks-node-group-role"
  }
}

# role과 여러 정책 연결
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy" # EKS 노드 기본 정책 (AmazonEKSWorkerNodePolicy)
}

resource "aws_iam_role_policy_attachment" "ecr_readonly_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly" # ECR 읽기 전용 정책 (AmazonEC2ContainerRegistryReadOnly)
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" # EKS VPC CNI 정책 (AmazonEKS_CNI_Policy)
}
