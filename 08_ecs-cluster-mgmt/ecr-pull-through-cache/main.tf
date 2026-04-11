data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_subnets" "default" {
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_vpc" "default" {
  default = true
}

resource "aws_ecr_repository" "main" {
  name                 = var.repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_secretsmanager_secret" "docker_hub" {
  count = local.docker_hub_credentials_enabled ? 1 : 0

  name = "ecr-pullthroughcache/${var.project_name}-docker-hub-cred"
}

resource "aws_secretsmanager_secret_version" "docker_hub" {
  count = local.docker_hub_credentials_enabled ? 1 : 0

  secret_id = aws_secretsmanager_secret.docker_hub[0].id
  secret_string = jsonencode({
    username    = var.docker_hub_username
    accessToken = var.docker_hub_access_token
  })
}

resource "aws_ecr_pull_through_cache_rule" "docker_hub" {
  ecr_repository_prefix = var.pull_through_cache_prefix
  upstream_registry_url = "registry-1.docker.io"
  credential_arn        = local.docker_hub_credentials_enabled ? aws_secretsmanager_secret.docker_hub[0].arn : null

  lifecycle {
    precondition {
      condition     = local.docker_hub_credentials_enabled
      error_message = "Docker Hub pull-through cache creation requires docker_hub_username and docker_hub_access_token in this environment."
    }
  }
}

resource "random_string" "key_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "tls_private_key" "instance" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "instance" {
  key_name   = "${var.project_name}-${random_string.key_suffix.result}"
  public_key = tls_private_key.instance.public_key_openssh
}

resource "aws_iam_role" "instance" {
  name_prefix = "${var.project_name}-ec2-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "ecr_pull_through_cache" {
  name_prefix = "${var.project_name}-ecr-"
  role        = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:BatchImportUpstreamImage",
          "ecr:CreateRepository",
          "ecr:DescribeImages",
          "ecr:DescribePullThroughCacheRules",
          "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name_prefix = "${var.project_name}-ec2-"
  role        = aws_iam_role.instance.name
}

resource "aws_security_group" "instance" {
  name_prefix = "${var.project_name}-ssh-"
  description = "Allow SSH access for the ECR practice EC2 instance"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidr_blocks
  }

  egress {
    description = "Outbound internet access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "main" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.instance.key_name
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.instance.id]
  user_data                   = <<-EOT
    #!/bin/bash
    dnf install -y docker awscli
    systemctl enable --now docker
    usermod -aG docker ec2-user
  EOT

  tags = {
    Name = "${var.project_name}-ec2"
  }
}
