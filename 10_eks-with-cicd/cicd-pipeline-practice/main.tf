###################################################################
# 파이프라인에 필요한 S3 버킷과 로그 그룹, 이미지 저장소
resource "aws_s3_bucket" "this" {
  bucket        = local.name
  tags          = local.tags
  force_destroy = true # 버킷을 삭제할 때 버킷 안의 모든 객체도 함께 삭제
}

# CodeBuild에서 로그를 저장할 로그 그룹
resource "aws_cloudwatch_log_group" "this" {
  name = local.name
  tags = local.tags
}

resource "aws_ecr_repository" "ecr_repo" {
  name = local.ecr_repo_name
  tags = local.tags

  force_delete = true
}


###################################################################
# CodePipeline에 사용될 IAM 역할 정의
resource "aws_iam_role" "code_pipeline_role" {
  name        = "${local.name}-${random_integer.unique_id.result}"
  description = "Role to be used by CodePipeline"
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

# CodePipeline에서 사용할 사용자 정의 정책
resource "aws_iam_policy" "this" {
  name        = local.name
  description = "Custom policies for CI"
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
      "Action": "codestar-connections:UseConnection",
      "Resource": "${aws_codestarconnections_connection.this.arn}"
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
# CodeBuild 프로젝트 구성
resource "aws_codebuild_project" "this_ci" {
  # CodeBuild : Continuous Integration
  name          = join("-", [local.subject, "ci", local.time_static])
  description   = "to build docker image about ${local.name}"
  build_timeout = "10"
  service_role  = aws_iam_role.code_pipeline_role.arn
  tags          = local.tags

  artifacts {
    type = "CODEPIPELINE"
  }

  # cache {
  #   type     = "S3"
  #   location = aws_s3_bucket.this.bucket
  # }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"                          # 이미지는 그대로 유지
    image                       = "aws/codebuild/amazonlinux-x86_64-standard:5.0" # 이미지 변경
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true # 도커 이미지를 빌드할 권한 활성화
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
    buildspec = "buildspec.yml"
  }
}

# CodeBuild에 대한 보안 그룹 생성
resource "aws_security_group" "codebuild_sg" {
  name        = "codebuild-security-group"
  description = "Security group for Code Build"
  vpc_id      = module.vpc.vpc_id # 사용할 VPC ID

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
# AWS CodeConnections 리소스 설정
resource "aws_codestarconnections_connection" "this" {
  name          = "my-codestar-connection" # 연결의 이름 (원하는 이름으로 설정)
  provider_type = "GitHub"                 # 사용하려는 Git 제공자 (GitHub, Bitbucket 등)
  tags          = local.tags               # 태그 추가
}

###################################################################
# CodePipeline 구성
resource "aws_codepipeline" "this" {
  # 순서 : CodeStar Connections - CodeBuild(CI) - Manual Approval
  name     = join("-", [local.subject, local.time_static]) # 파이프라인 이름을 고유하게 설정
  role_arn = aws_iam_role.code_pipeline_role.arn           # 파이프라인이 사용할 IAM 역할
  tags     = local.tags                                    # 태그 추가

  artifact_store {
    location = aws_s3_bucket.this.bucket # S3를 아티팩트 저장소로 설정
    type     = "S3"                      # 산출물을 저장할 유형(S3 버킷)
  }

  # 첫 번째 단계: 소스 가져오기 (AWS CodeStar Connections 사용)
  stage {
    name = "Source" # 단계 이름

    action {
      name             = "Source"                   # 액션 이름
      category         = "Source"                   # 액션 유형: 소스 단계
      owner            = "AWS"                      # 소유자: AWS
      provider         = "CodeStarSourceConnection" # CodeStar Connections 사용
      version          = "1"                        # 액션 버전
      output_artifacts = ["source_output"]          # 이 단계에서 나오는 산출물
      run_order        = 1                          # 실행 순서
      configuration = {
        ConnectionArn        = aws_codestarconnections_connection.this.arn # CodeStar Connections ARN
        FullRepositoryId     = var.project_name                            # GitHub 리포지토리 ID
        BranchName           = "master"                                    # 빌드할 브랜치 이름
        OutputArtifactFormat = "CODE_ZIP"                                  # 산출물 형식 (ZIP 파일로 출력)
      }
    }
  }

  # 두 번째 단계: 빌드 수행 (AWS CodeBuild 사용)
  stage {
    name = "Build" # 단계 이름

    action {
      name             = "Build"           # 액션 이름
      category         = "Build"           # 액션 유형: 빌드 단계
      owner            = "AWS"             # 소유자: AWS
      provider         = "CodeBuild"       # 빌드 제공자: AWS CodeBuild
      version          = "1"               # 액션 버전
      input_artifacts  = ["source_output"] # 이전 단계에서 나온 소스 아티팩트
      output_artifacts = ["build_output"]  # 빌드 결과 아티팩트
      run_order        = 1                 # 실행 순서
      configuration = {
        ProjectName = aws_codebuild_project.this_ci.name # CodeBuild 프로젝트 이름
      }
    }
  }
}


###################################################################
# GitHub Webhook 설정
resource "aws_codepipeline_webhook" "github_webhook" {
  name            = "github-webhook"           # Webhook 이름
  target_action   = "Source"                   # 파이프라인의 소스 단계에서 트리거
  target_pipeline = aws_codepipeline.this.name # 트리거할 파이프라인 이름

  authentication = "GITHUB_HMAC" # GitHub HMAC 인증 방식 사용

  authentication_configuration {
    secret_token = local.github_webhook_secret # GitHub Webhook 인증에 사용할 시크릿 토큰
  }

  filter {
    json_path    = "$.ref"             # 브랜치 참조 경로
    match_equals = "refs/heads/master" # master 브랜치에서만 트리거
  }
}

# Webhook 트리거 권한 부여
resource "aws_iam_role_policy" "allow_codepipeline_webhook" {
  role = aws_iam_role.code_pipeline_role.id
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : "codepipeline:StartPipelineExecution",
        "Resource" : aws_codepipeline.this.arn # CodePipeline을 실행할 권한 부여
      }
    ]
  })
}
