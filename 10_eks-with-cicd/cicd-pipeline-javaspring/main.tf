# ================================================================
# CI/CD 파이프라인 핵심 인프라
#
# 전체 흐름:
#   개발자가 CodeCommit에 코드 push
#   → EventBridge가 감지 → CodePipeline 자동 실행
#   → CodeBuild가 Docker 이미지 빌드 → ECR에 push
#   → update_apps.sh가 javaspring-apps deployment.yaml 태그 업데이트
#   → ArgoCD가 변경 감지 → EKS에 자동 배포
# ================================================================

# S3 버킷 — CodePipeline이 각 단계(Source → Build) 사이에 파일을 주고받는 임시 창고
# 예: Source 단계에서 받은 코드 zip을 S3에 저장 → Build 단계에서 꺼내서 빌드
resource "aws_s3_bucket" "this" {
  bucket        = local.name
  tags          = local.tags
  force_destroy = true # terraform destroy 시 버킷 안의 파일도 함께 삭제 (비어있지 않아도 삭제 가능)
}

# CloudWatch 로그 그룹 — CodeBuild의 빌드 로그(컴파일 결과, 오류 메시지 등)를 저장
# AWS 콘솔에서 빌드 실패 원인 확인 시 이 로그를 조회
resource "aws_cloudwatch_log_group" "this" {
  name = local.name
  tags = local.tags
}

# ECR(Elastic Container Registry) — Docker 이미지를 저장하는 AWS 전용 컨테이너 이미지 저장소
# CodeBuild가 빌드한 Java Spring Boot 이미지를 여기에 push
# EKS 파드가 이 이미지를 pull해서 실행
resource "aws_ecr_repository" "ecr_repo" {
  name = local.ecr_repo_name
  tags = local.tags

  force_delete = true # terraform destroy 시 이미지가 남아있어도 저장소 삭제 허용
}


# ================================================================
# CodeCommit 저장소 생성
#
# CodeCommit이란?
#   AWS가 제공하는 Git 저장소 서비스 (GitHub의 AWS 버전)
#   두 개의 저장소를 사용하는 이유:
#   - javaspring: 개발자가 작성한 Java 소스 코드 (빌드 대상)
#   - javaspring-apps: Kubernetes 배포 설정 파일 (ArgoCD가 읽는 곳)
# ================================================================

# javaspring — Java Spring Boot 앱 소스 코드 저장소
# 개발자가 코드를 수정해서 push → EventBridge가 감지 → 빌드 자동 시작
resource "aws_codecommit_repository" "javaspring" {
  repository_name = "javaspring"
  description     = "Java Spring Boot 앱 소스 코드 (GitHub gasbugs/javaspring에서 복제)"
  tags            = local.tags
}

# javaspring-apps — Kubernetes 매니페스트(배포 설정) 저장소
# ArgoCD가 이 저장소를 감시 → deployment.yaml 변경 시 EKS에 자동 배포
# CodeBuild의 update_apps.sh가 이미지 태그를 업데이트하는 대상
resource "aws_codecommit_repository" "javaspring_apps" {
  repository_name = "javaspring-apps"
  description     = "ArgoCD용 K8s 매니페스트 (GitHub gasbugs/javaspring-apps에서 복제)"
  tags            = local.tags
}


# ================================================================
# IAM 역할(Role) 생성
#
# IAM 역할이란?
#   사람이 아닌 AWS 서비스가 다른 서비스를 사용할 때 필요한 "권한 증명서"
#   예: CodeBuild가 ECR에 이미지를 push하려면 ECR 쓰기 권한이 필요
#       → IAM 역할에 ECR 권한을 부여하고 CodeBuild에 역할을 할당
#
# 이 역할을 공유하는 서비스:
#   - CodeBuild: Docker 빌드 + ECR push + CodeCommit GitPush
#   - CodePipeline: 파이프라인 실행 오케스트레이션
#   - EventBridge: CodeCommit push 감지 후 파이프라인 트리거
# ================================================================
resource "aws_iam_role" "code_pipeline_role" {
  name        = "${local.name}-${random_integer.unique_id.result}"
  description = "Role to be used by CodePipeline"
  tags        = local.tags

  # assume_role_policy: 이 역할을 위임받을 수 있는 서비스 목록
  # sts:AssumeRole = "이 역할의 권한을 내가 대신 행사하겠다"는 요청
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

# ================================================================
# IAM 정책(Policy) — 역할이 실제로 할 수 있는 행동 목록
#
# 정책이란?
#   "어떤 서비스의 어떤 기능을 사용할 수 있는가"를 명시한 문서
#   각 Sid(Statement ID)는 서비스별로 허용할 행동을 그룹화
# ================================================================
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
        "${aws_codecommit_repository.javaspring.arn}"
      ]
    },
    {
      "Sid"   : "CodeCommitAppsRepo",
      "Effect": "Allow",
      "Action": [
        "codecommit:GetBranch",
        "codecommit:GetCommit",
        "codecommit:GetRepository",
        "codecommit:GitPull",
        "codecommit:GitPush"
      ],
      "Resource": [
        "${aws_codecommit_repository.javaspring_apps.arn}"
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

# 위에서 만든 정책을 역할에 연결 — 역할이 정책의 권한을 실제로 사용할 수 있게 됨
resource "aws_iam_role_policy_attachment" "this_customer_managed" {
  role       = aws_iam_role.code_pipeline_role.name
  policy_arn = aws_iam_policy.this.arn
}


# ================================================================
# CodeBuild 프로젝트 — Docker 이미지 빌드 및 ECR 푸시 담당
#
# CodeBuild란?
#   소스 코드를 받아 빌드(컴파일·테스트·패키징)하고 결과물을 저장하는 서비스
#   buildspec.yml 파일에 정의된 명령어를 순서대로 실행
#
# Java Spring Boot 빌드 흐름 (buildspec.yml):
#   pre_build  → ECR 로그인, 이미지 태그 설정, git 설정
#   build      → Maven으로 컴파일·테스트 후 Docker 이미지 빌드
#   post_build → ECR에 이미지 push → javaspring-apps 이미지 태그 자동 업데이트
# ================================================================
resource "aws_codebuild_project" "this_ci" {
  name          = join("-", [local.subject, "ci", local.time_static])
  description   = "Java Spring Boot 앱 Docker 멀티 스테이지 빌드 및 ECR 푸시"
  build_timeout = "20" # 분 단위 — Maven 의존성 다운로드 포함으로 Flask보다 빌드 시간 더 소요
  service_role  = aws_iam_role.code_pipeline_role.arn
  tags          = local.tags

  # artifacts: 빌드 결과물 처리 방식
  # CODEPIPELINE → CodePipeline이 관리하는 S3에 자동 저장
  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"           # 3GB RAM, 2 vCPU — 소규모 빌드에 적합
    image                       = "aws/codebuild/amazonlinux-x86_64-standard:5.0" # AWS 공식 빌드 환경 이미지
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true # Docker 빌드는 컨테이너 안에서 Docker를 실행해야 해서 권한 상승 필요

    # buildspec.yml에서 $ECR_REPO_URI로 사용 — Docker 이미지를 push할 저장소 주소
    environment_variable {
      name  = "ECR_REPO_URI"
      value = aws_ecr_repository.ecr_repo.repository_url
    }

    # buildspec.yml에서 $AWS_DEFAULT_REGION으로 사용 — ECR 로그인 시 리전 지정
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }

    # buildspec.yml의 update_apps.sh에서 $APPS_REPO_URL로 사용
    # 빌드 후 javaspring-apps 저장소를 클론해서 이미지 태그를 업데이트하기 위해 필요
    environment_variable {
      name  = "APPS_REPO_URL"
      value = aws_codecommit_repository.javaspring_apps.clone_url_http
    }
  }

  # vpc_config: CodeBuild를 VPC 프라이빗 서브넷 안에서 실행
  # 이유: ECR, CodeCommit 등 AWS 서비스에 VPC 내부 경로로 접근 (보안 강화)
  # 인터넷 접근이 필요한 경우 NAT 게이트웨이를 통해 나감
  vpc_config {
    vpc_id = module.vpc.vpc_id

    subnets = [
      for k, v in module.vpc.private_subnets : module.vpc.private_subnets[k]
    ]

    security_group_ids = [aws_security_group.codebuild_sg.id]
  }

  # 빌드 로그를 CloudWatch Logs에 저장 — 빌드 실패 시 원인 분석에 사용
  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.this.name
      stream_name = local.name
    }
  }

  # javaspring 레포 루트에 있는 buildspec.yml을 빌드 명세로 사용
  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }
}

# CodeBuild 전용 보안 그룹 — VPC 내부에서 CodeBuild가 사용할 네트워크 접근 규칙
resource "aws_security_group" "codebuild_sg" {
  name        = "codebuild-security-group-${local.time_static}"
  description = "Security group for CodeBuild in VPC"
  vpc_id      = module.vpc.vpc_id

  # 인바운드(들어오는 트래픽): 같은 보안 그룹 멤버끼리만 허용
  # self = true → 동일 보안 그룹에 속한 리소스끼리의 내부 통신만 허용
  # 외부 인터넷이나 다른 서브넷에서 들어오는 요청은 모두 차단
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  # 아웃바운드(나가는 트래픽): 모든 목적지로 허용
  # ECR 이미지 push, S3 업로드, CodeCommit pull, NAT 게이트웨이를 통한 인터넷 접근 등 모두 허용
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


# ================================================================
# EventBridge 규칙 — 코드 push 감지 시 파이프라인 자동 트리거
#
# EventBridge란?
#   AWS 서비스 간 이벤트를 연결해주는 이벤트 버스
#   "CodeCommit에 커밋이 올라오면 → CodePipeline을 실행하라" 와 같은
#   자동화 규칙을 설정할 때 사용
#
# polling 방식 대비 장점:
#   polling: 5분마다 변경 여부 확인 → 최대 5분 지연
#   EventBridge: 커밋 즉시 감지 → 수 초 이내 파이프라인 시작
# ================================================================
resource "aws_cloudwatch_event_rule" "codecommit_trigger" {
  name        = "${local.name}-trigger"
  description = "javaspring CodeCommit main 브랜치 변경 시 파이프라인 트리거"
  tags        = local.tags

  # 감지할 이벤트 조건 정의
  event_pattern = jsonencode({
    source      = ["aws.codecommit"]                          # CodeCommit 서비스 이벤트만 감지
    detail-type = ["CodeCommit Repository State Change"]      # 저장소 상태 변경 이벤트
    resources   = [aws_codecommit_repository.javaspring.arn]  # javaspring 저장소만 감시
    detail = {
      event         = ["referenceUpdated", "referenceCreated"] # push 또는 브랜치 생성 시
      referenceName = ["main"]                                 # main 브랜치만 트리거
    }
  })
}

# EventBridge 이벤트 발생 시 실행할 타겟(대상) 연결
# CodeCommit push 이벤트 → CodePipeline 실행
resource "aws_cloudwatch_event_target" "pipeline_trigger" {
  rule     = aws_cloudwatch_event_rule.codecommit_trigger.name
  arn      = aws_codepipeline.this.arn                      # 실행할 파이프라인
  role_arn = aws_iam_role.code_pipeline_role.arn            # 파이프라인 실행 권한이 있는 역할
}


# ================================================================
# CodePipeline — CI/CD 파이프라인 오케스트레이터
#
# CodePipeline이란?
#   여러 단계(Source → Build → Deploy 등)로 구성된 자동화 워크플로
#   각 단계의 결과물을 S3에 저장하고 다음 단계로 전달
#
# 이 파이프라인 구성:
#   Stage 1 (Source): CodeCommit에서 소스 코드 다운로드
#   Stage 2 (Build):  CodeBuild로 Docker 이미지 빌드 + ECR push
#                     + javaspring-apps 이미지 태그 자동 업데이트
# ================================================================
resource "aws_codepipeline" "this" {
  name     = join("-", [local.subject, local.time_static])
  role_arn = aws_iam_role.code_pipeline_role.arn
  tags     = local.tags

  # 파이프라인 각 단계 사이에 파일을 교환하는 S3 버킷 지정
  artifact_store {
    location = aws_s3_bucket.this.bucket
    type     = "S3"
  }

  # Stage 1: Source — CodeCommit에서 최신 코드를 가져와 S3에 저장
  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"] # 다음 단계(Build)로 전달할 산출물 이름
      run_order        = 1

      configuration = {
        RepositoryName       = aws_codecommit_repository.javaspring.repository_name
        BranchName           = "main"
        PollForSourceChanges = "false"      # EventBridge로 트리거하므로 5분 polling 비활성화
        OutputArtifactFormat = "CODE_ZIP"   # 소스를 zip으로 압축해서 S3에 저장
      }
    }
  }

  # Stage 2: Build — CodeBuild로 Docker 이미지 빌드 + ECR push + apps 이미지 태그 업데이트
  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]  # Source 단계에서 받은 소스 zip
      output_artifacts = ["build_output"]   # 빌드 결과물 (이미지 태그 정보 등)
      run_order        = 1

      configuration = {
        ProjectName = aws_codebuild_project.this_ci.name
      }
    }
  }
}
