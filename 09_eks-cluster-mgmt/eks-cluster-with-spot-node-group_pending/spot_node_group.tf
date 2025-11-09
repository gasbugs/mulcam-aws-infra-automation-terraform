
# 클러스터를 참조하여 외부에서 노드 그룹 작성
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
}

# 노드 그룹에 구성할 role 작성
resource "aws_iam_role" "eks_node_role" {
  name = "eks-node-group-role"

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
