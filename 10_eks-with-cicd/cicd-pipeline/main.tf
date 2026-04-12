###################################################################
# 파이프라인에 필요한 S3 버킷과 로그 그룹, 이미지 저장소
# S3는 CodePipeline이 스테이지 간 산출물을 주고받는 중간 저장소 역할
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

# 빌드된 Docker 이미지를 저장할 ECR(Elastic Container Registry) 저장소
resource "aws_ecr_repository" "ecr_repo" {
  name = local.ecr_repo_name
  tags = local.tags

  force_delete = true
}


###################################################################
# CodeCommit 저장소 생성
# flask-example: Flask Python 앱 소스 코드를 저장 (CodePipeline 소스)
resource "aws_codecommit_repository" "flask_example" {
  repository_name = "flask-example"
  description     = "Flask Python 앱 소스 코드 (GitHub gasbugs/flask-example에서 복제)"
  tags            = local.tags
}

# flask-example-apps: ArgoCD가 읽어갈 Kubernetes 매니페스트 저장소
resource "aws_codecommit_repository" "flask_example_apps" {
  repository_name = "flask-example-apps"
  description     = "ArgoCD용 K8s 매니페스트 (GitHub gasbugs/flask-example-apps에서 복제)"
  tags            = local.tags
}


###################################################################
# CodePipeline에 사용될 IAM 역할 정의
# IAM 역할(Role): AWS 서비스가 다른 서비스를 사용할 때 필요한 "권한 증명서"
# CodeBuild(빌드), CodePipeline(파이프라인 실행), EventBridge(자동 트리거) 세 서비스가
# 이 하나의 역할을 공유해서 S3·ECR·CodeCommit 등에 접근함
resource "aws_iam_role" "code_pipeline_role" {
  name        = "${local.name}-${random_integer.unique_id.result}"
  description = "Role to be used by CodePipeline"
  tags        = local.tags

  # assume_role_policy: 이 역할을 "위임받을 수 있는" 서비스 목록
  # sts:AssumeRole = "이 역할의 권한을 내가 대신 행사하겠다"는 요청
  # Principal 서비스 목록:
  #   - codebuild.amazonaws.com    : Docker 이미지 빌드 서비스
  #   - codepipeline.amazonaws.com : CI/CD 파이프라인 오케스트레이션 서비스
  #   - events.amazonaws.com       : EventBridge — CodeCommit push 감지 후 파이프라인 트리거
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
# GitHub 연결(codestar-connections) 대신 CodeCommit 권한으로 교체
# 각 Sid(Statement ID)는 역할이 접근할 수 있는 AWS 서비스 범위를 구분
resource "aws_iam_policy" "this" {
  name        = local.name
  description = "Custom policies for CI/CD pipeline with CodeCommit"
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
        "codecommit:GitPull"
      ],
      "Resource": [
        "${aws_codecommit_repository.flask_example.arn}"
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
      "Sid"   : "EC2",
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
# Flask Python 앱을 Docker 이미지로 빌드하여 ECR에 푸시
resource "aws_codebuild_project" "this_ci" {
  name          = join("-", [local.subject, "ci", local.time_static])
  description   = "Flask Python 앱 Docker 이미지 빌드 및 ECR 푸시"
  build_timeout = "10"
  service_role  = aws_iam_role.code_pipeline_role.arn
  tags          = local.tags

  artifacts {
    type = "CODEPIPELINE" # 산출물을 CodePipeline이 관리하는 S3에 저장
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true # Docker 이미지 빌드를 위해 권한 상승 필요

    # ECR 저장소 URI를 환경변수로 주입 — buildspec.yml에서 $ECR_REPO_URI로 사용
    environment_variable {
      name  = "ECR_REPO_URI"
      value = aws_ecr_repository.ecr_repo.repository_url
    }

    # AWS 리전을 환경변수로 주입 — ECR 로그인 시 사용
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }
  }

  # vpc_config: CodeBuild가 VPC 프라이빗 서브넷에서 실행되도록 설정
  # → ECR, CodeCommit 등 VPC 엔드포인트 또는 NAT 게이트웨이를 통해 접근
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
    buildspec = "buildspec.yml" # flask-example 레포 루트에 있는 buildspec.yml 사용
  }
}

# CodeBuild가 VPC 내부에서 실행되기 위한 보안 그룹
resource "aws_security_group" "codebuild_sg" {
  name        = "codebuild-security-group-${local.time_static}"
  description = "Security group for CodeBuild in VPC"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    # self = true: 같은 보안 그룹에 속한 리소스끼리만 내부 통신 허용
    # (외부 인터넷이나 다른 서브넷에서 들어오는 인바운드 트래픽은 차단)
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # ECR push, S3 업로드, CodeCommit pull 등 외부 서비스 접근 허용
  }

  tags = {
    Name = "codebuild-security-group"
  }
}


###################################################################
# EventBridge 규칙 — CodeCommit 저장소에 커밋이 올라오면 파이프라인 자동 실행
# polling 방식(5분 주기) 대신 이벤트 기반으로 즉시 트리거
resource "aws_cloudwatch_event_rule" "codecommit_trigger" {
  name        = "${local.name}-trigger"
  description = "flask-example CodeCommit 저장소 main 브랜치 변경 시 파이프라인 트리거"
  tags        = local.tags

  event_pattern = jsonencode({
    source      = ["aws.codecommit"]
    detail-type = ["CodeCommit Repository State Change"]
    resources   = [aws_codecommit_repository.flask_example.arn]
    detail = {
      event         = ["referenceUpdated", "referenceCreated"]
      referenceName = ["main"] # main 브랜치에 push될 때만 트리거
    }
  })
}

# EventBridge가 CodePipeline을 실행하도록 타겟 연결
resource "aws_cloudwatch_event_target" "pipeline_trigger" {
  rule     = aws_cloudwatch_event_rule.codecommit_trigger.name
  arn      = aws_codepipeline.this.arn
  role_arn = aws_iam_role.code_pipeline_role.arn # 파이프라인 실행 권한이 있는 역할 사용
}


###################################################################
# CodePipeline 구성
# 순서: CodeCommit(소스) → CodeBuild(빌드·ECR 푸시)
resource "aws_codepipeline" "this" {
  name     = join("-", [local.subject, local.time_static])
  role_arn = aws_iam_role.code_pipeline_role.arn
  tags     = local.tags

  artifact_store {
    location = aws_s3_bucket.this.bucket # 스테이지 간 산출물을 S3에 저장
    type     = "S3"
  }

  # 첫 번째 단계: CodeCommit에서 소스 가져오기
  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"  # GitHub 대신 CodeCommit 사용
      version          = "1"
      output_artifacts = ["source_output"]
      run_order        = 1
      configuration = {
        RepositoryName       = aws_codecommit_repository.flask_example.repository_name
        BranchName           = "main"
        PollForSourceChanges = "false" # EventBridge로 트리거하므로 polling 비활성화
        OutputArtifactFormat = "CODE_ZIP"
      }
    }
  }

  # 두 번째 단계: CodeBuild로 Flask Docker 이미지 빌드 및 ECR 푸시
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
