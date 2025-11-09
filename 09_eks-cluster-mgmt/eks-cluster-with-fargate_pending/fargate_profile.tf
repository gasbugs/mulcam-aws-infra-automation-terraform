resource "aws_eks_fargate_profile" "example_fargate_profile" {
  cluster_name           = module.eks.cluster_name
  fargate_profile_name   = "fargate-profile-a"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution_role.arn


  # 적용할 네임스페이스 및 선택자 지정
  selector {
    namespace = "fargate-namespace"
    labels = {
      fargate_label = "fargate-profile-a"
    }
  }

  # 사용할 서브넷 설정
  subnet_ids = module.vpc.private_subnets
}

resource "aws_iam_role" "fargate_pod_execution_role" {
  name = "eks-fargate-pod-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks-fargate-pods.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_fargate_policy_attach" {
  role       = aws_iam_role.fargate_pod_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}
