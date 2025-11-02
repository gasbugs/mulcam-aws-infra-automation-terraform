
provider "helm" {
  kubernetes = {
    config_path = "${pathexpand("~")}/.kube/config"
  }
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler" # https://kubernetes.github.io/autoscaler/index.yaml
  chart      = "cluster-autoscaler"
  version    = "9.43.0" # 최신 버전 확인 필요
  namespace  = "kube-system"

  values = [
    templatefile("${path.module}/cluster-autoscaler-values.yaml.tmpl", {
      cluster_name = module.eks.cluster_name
      aws_region   = var.aws_region
    })
  ]

  depends_on = [null_resource.eks_kubectl_config]
}

resource "kubernetes_service_account" "cluster_autoscaler" {
  metadata {
    name      = "cluster-autoscaler"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = module.irsa-cluster-autoscaler.iam_role_arn
    }
  }
  depends_on = [null_resource.eks_kubectl_config]
}

# IRSA 모듈 정의 (cluster-autoscaler)
module "irsa-cluster-autoscaler" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.20"

  create_role                   = true
  role_name                     = "AmazonEKSClusterAutoscalerRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [aws_iam_policy.cluster_autoscaler_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:cluster-autoscaler"]
}

resource "aws_iam_policy" "cluster_autoscaler_policy" {
  name        = "ClusterAutoscalerPolicy"
  description = "Policy for cluster-autoscaler to interact with AWS Auto Scaling and EC2"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ],
        Resource = ["*"]
      },
      {
        Effect = "Allow",
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ],
        Resource = ["*"]
      }
    ]
  })
}
