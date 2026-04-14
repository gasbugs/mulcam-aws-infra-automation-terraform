###################################################################
# netflux-app 소스 코드를 저장하는 CodeCommit 저장소
resource "aws_codecommit_repository" "netflux_app" {
  repository_name = var.app_name                         # 저장소 이름 (예: netflux)
  description     = "Source repository for netflux Flask application"
  tags            = local.tags
}

# ArgoCD가 감시하는 Kubernetes 배포 매니페스트 저장소
resource "aws_codecommit_repository" "netflux_deploy" {
  repository_name = "${var.app_name}-deploy"             # 저장소 이름 (예: netflux-deploy)
  description     = "GitOps deployment manifests for ArgoCD"
  tags            = local.tags
}


###################################################################
# 파이프라인에 필요한 S3 버킷과 로그 그룹, 이미지 저장소
resource "aws_s3_bucket" "this" {
  bucket        = "${local.name}-artifacts"
  tags          = local.tags
  force_destroy = true # 버킷을 삭제할 때 버킷 안의 모든 객체도 함께 삭제
}

# CodeBuild에서 로그를 저장할 로그 그룹
resource "aws_cloudwatch_log_group" "this" {
  name = local.name
  tags = local.tags
}

# Docker 이미지를 저장할 ECR 저장소
resource "aws_ecr_repository" "ecr_repo" {
  name = local.ecr_repo_name
  tags = local.tags

  force_delete = true
}


###################################################################
# CodePipeline, CodeBuild, EventBridge에서 사용할 IAM 역할
resource "aws_iam_role" "code_pipeline_role" {
  name        = "${local.name}-${random_integer.unique_id.result}"
  description = "IAM role for CodePipeline, CodeBuild, and CloudWatch Events"
  tags        = local.tags

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid"   : "",
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "codebuild.amazonaws.com",
          "codepipeline.amazonaws.com",
          "events.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

# CI/CD 파이프라인에서 필요한 권한을 정의한 사용자 정의 정책
resource "aws_iam_policy" "this" {
  name        = local.name
  description = "Custom IAM policy for CI/CD pipeline (CodeBuild, CodePipeline, CodeCommit, ECR, S3, CloudWatch)"
  tags        = local.tags

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid"   : "CodeBuild",
      "Effect": "Allow",
      "Action": [
        "codebuild:CreateReportGroup",
        "codebuild:CreateReport",
        "codebuild:UpdateReport",
        "codebuild:BatchPutTestCases",
        "codebuild:BatchPutCodeCoverages",
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild"
      ],
      "Resource": [
        "arn:aws:codebuild:${var.aws_region}:${local.account_id}:project/${local.subject}*"
      ]
    },
    {
      "Sid"   : "CodePipeline",
      "Effect": "Allow",
      "Action": [
        "codepipeline:StartPipelineExecution"
      ],
      "Resource": [
        "arn:aws:codepipeline:${var.aws_region}:${local.account_id}:${local.subject}*"
      ]
    },
    {
      "Sid"   : "CodeCommit",
      "Effect": "Allow",
      "Action": [
        "codecommit:GetBranch",
        "codecommit:GetCommit",
        "codecommit:GetRepository",
        "codecommit:GetUploadArchiveStatus",
        "codecommit:UploadArchive",
        "codecommit:CancelUploadArchive",
        "codecommit:ListBranches",
        "codecommit:GitPull",
        "codecommit:GitPush",
        "codecommit:CreateBranch",
        "codecommit:PutFile"
      ],
      "Resource": [
        "${aws_codecommit_repository.netflux_app.arn}",
        "${aws_codecommit_repository.netflux_deploy.arn}"
      ]
    },
    {
      "Sid"   : "ECRGetToken",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": [
        "*"
      ]
    },
    {
      "Sid"   : "ECRRegistry",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:CompleteLayerUpload",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart"
      ],
      "Resource": [
        "${aws_ecr_repository.ecr_repo.arn}"
      ]
    },
    {
      "Sid"   : "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": [
        "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:${local.name}*:log-stream:${local.name}*/*"
      ]
    },
    {
      "Sid"   : "S3",
      "Effect": "Allow",
      "Action": [
        "s3:*"
      ],
      "Resource": [
        "${aws_s3_bucket.this.arn}",
        "${aws_s3_bucket.this.arn}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

# 사용자 정의 정책과 역할 연결
resource "aws_iam_role_policy_attachment" "this_customer_managed" {
  role       = aws_iam_role.code_pipeline_role.name
  policy_arn = aws_iam_policy.this.arn
}


###################################################################
# CodeBuild 프로젝트 구성 — Docker 이미지 빌드 및 ECR 푸시
resource "aws_codebuild_project" "this_ci" {
  name          = join("-", [local.subject, "ci", local.time_static])
  description   = "Build Docker image for ${local.name} and push to ECR"
  build_timeout = "10"
  service_role  = aws_iam_role.code_pipeline_role.arn
  tags          = local.tags

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true # Docker 이미지 빌드를 위한 권한 모드 활성화

    # buildspec.yml 에서 참조할 환경 변수
    environment_variable {
      name  = "ECR_REPO_NAME"
      value = local.ecr_repo_name
    }

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = local.account_id
    }

    environment_variable {
      name  = "DEPLOY_REPO"
      value = aws_codecommit_repository.netflux_deploy.repository_name
    }
  }

  vpc_config {
    vpc_id = module.vpc.vpc_id

    subnets = [
      for k, v in module.vpc.private_subnets : module.vpc.private_subnets[k]
    ]

    security_group_ids = [aws_security_group.codebuild_sg.id]
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.this.name
      stream_name = local.name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml" # netflux-app 루트에 위치한 빌드 명세 파일
  }
}

# CodeBuild VPC 내 실행을 위한 보안 그룹
resource "aws_security_group" "codebuild_sg" {
  name        = "codebuild-security-group"
  description = "Security group for CodeBuild project running inside VPC"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "codebuild-security-group"
  }
}


###################################################################
# CodeCommit push 이벤트를 감지해서 CodePipeline을 자동 트리거하는 EventBridge 규칙
resource "aws_cloudwatch_event_rule" "codecommit_trigger" {
  name        = "${local.name}-trigger"
  description = "Trigger CodePipeline when netflux-app main branch is updated"
  tags        = local.tags

  event_pattern = jsonencode({
    source      = ["aws.codecommit"]
    detail-type = ["CodeCommit Repository State Change"]
    resources   = [aws_codecommit_repository.netflux_app.arn]
    detail = {
      event         = ["referenceCreated", "referenceUpdated"]
      referenceType = ["branch"]
      referenceName = ["main"]
    }
  })
}

# EventBridge 이벤트가 발생했을 때 CodePipeline을 실행하도록 연결
resource "aws_cloudwatch_event_target" "pipeline_trigger" {
  rule     = aws_cloudwatch_event_rule.codecommit_trigger.name
  arn      = aws_codepipeline.this.arn
  role_arn = aws_iam_role.code_pipeline_role.arn # CodePipeline 실행 권한을 가진 역할
}


###################################################################
# CodePipeline 구성 — Source(CodeCommit) → Build(CodeBuild)
resource "aws_codepipeline" "this" {
  name     = join("-", [local.subject, local.time_static])
  role_arn = aws_iam_role.code_pipeline_role.arn
  tags     = local.tags

  artifact_store {
    location = aws_s3_bucket.this.bucket
    type     = "S3"
  }

  # 1단계: CodeCommit에서 소스 가져오기
  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"    # GitHub 대신 CodeCommit 사용
      version          = "1"
      output_artifacts = ["source_output"]
      run_order        = 1
      configuration = {
        RepositoryName       = aws_codecommit_repository.netflux_app.repository_name
        BranchName           = "main"
        OutputArtifactFormat = "CODE_ZIP"
        PollForSourceChanges = "false"   # EventBridge로 트리거하므로 폴링 비활성화
      }
    }
  }

  # 2단계: CodeBuild로 Docker 이미지 빌드 및 ECR 푸시
  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      run_order        = 1
      configuration = {
        ProjectName = aws_codebuild_project.this_ci.name
      }
    }
  }
}
