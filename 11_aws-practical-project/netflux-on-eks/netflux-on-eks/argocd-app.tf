###################################################################
# ArgoCD가 CodeCommit 저장소에 접근할 때 사용하는 전용 IAM 사용자
# 이 사용자는 사람이 사용하는 계정이 아니라 ArgoCD가 Git pull 할 때만 쓰는 서비스 계정
resource "aws_iam_user" "argocd_codecommit" {
  name = "${var.app_name}-argocd-codecommit"
  tags = local.tags
}

# 위 IAM 사용자에게 netflux-deploy 저장소만 읽을 수 있는 권한 부여
# 최소 권한 원칙: 꼭 필요한 읽기 권한만 허용, 쓰기/삭제 권한은 없음
resource "aws_iam_user_policy" "argocd_codecommit" {
  name = "${var.app_name}-argocd-codecommit"
  user = aws_iam_user.argocd_codecommit.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "codecommit:GitPull",        # 저장소에서 코드를 가져오는 권한
        "codecommit:GetBranch",      # 브랜치 정보를 조회하는 권한
        "codecommit:GetCommit",      # 특정 커밋 정보를 조회하는 권한
        "codecommit:GetRepository",  # 저장소 메타데이터를 조회하는 권한
        "codecommit:ListBranches"    # 브랜치 목록을 조회하는 권한
      ]
      Resource = aws_codecommit_repository.netflux_deploy.arn
    }]
  })
}

# CodeCommit 전용 HTTPS 자격증명 생성
# 일반 AWS 액세스 키와 다른, Git 명령어 전용 아이디/비밀번호를 자동으로 발급
# ArgoCD가 https://git-codecommit... 주소로 접속할 때 이 자격증명을 사용
resource "aws_iam_service_specific_credential" "argocd_codecommit" {
  service_name = "codecommit.amazonaws.com"
  user_name    = aws_iam_user.argocd_codecommit.name
}


###################################################################
# ArgoCD Helm 설치 후 CRD(Custom Resource Definition)가 클러스터에 완전히 등록될 때까지 대기
# ArgoCD Application 리소스는 CRD가 등록된 이후에만 생성 가능하므로 30초 대기
resource "time_sleep" "wait_for_argocd_crds" {
  create_duration = "30s"
  depends_on      = [helm_release.argocd]
}


###################################################################
# ArgoCD 저장소 자격증명 Secret
# 이 Secret이 있어야 ArgoCD가 netflux-deploy CodeCommit 저장소에 접속 가능
# 라벨 argocd.argoproj.io/secret-type: repository 가 있으면 ArgoCD가 자동으로 저장소로 인식
resource "kubernetes_secret_v1" "argocd_repo_secret" {
  metadata {
    name      = "netflux-deploy-repo"
    namespace = "argocd" # ArgoCD가 설치된 네임스페이스에 생성해야 함

    # 이 라벨이 있어야 ArgoCD가 "아, 이건 저장소 자격증명이구나" 하고 인식
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  # 저장소 접속에 필요한 정보를 담는 부분
  data = {
    type     = "git"                                                                              # 저장소 유형: git
    url      = aws_codecommit_repository.netflux_deploy.clone_url_http                           # 저장소 주소
    username = aws_iam_service_specific_credential.argocd_codecommit.service_user_name           # CodeCommit 전용 아이디
    password = aws_iam_service_specific_credential.argocd_codecommit.service_password            # CodeCommit 전용 비밀번호
  }

  # ArgoCD CRD가 완전히 등록된 이후에 생성 (30초 대기 후)
  depends_on = [time_sleep.wait_for_argocd_crds]
}


###################################################################
# ArgoCD Application 생성
# kubernetes_manifest는 plan 단계에서 클러스터 연결이 필요해 신규 배포 시 실패하므로
# null_resource + local-exec 방식으로 kubectl을 직접 실행해 Application을 생성
resource "null_resource" "argocd_application" {
  # 아래 값이 바뀌면 Application을 다시 생성
  triggers = {
    repo_url = aws_codecommit_repository.netflux_deploy.clone_url_http
    app_name = var.app_name
  }

  provisioner "local-exec" {
    # kubeconfig를 갱신한 뒤 ArgoCD Application 매니페스트를 클러스터에 직접 적용
    command = <<-EOF
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} \
        --profile ${var.aws_profile}

      kubectl apply -f - <<YAML
      apiVersion: argoproj.io/v1alpha1
      kind: Application
      metadata:
        name: ${var.app_name}
        namespace: argocd
      spec:
        project: default
        source:
          repoURL: ${aws_codecommit_repository.netflux_deploy.clone_url_http}
          targetRevision: main
          path: "."
        destination:
          server: https://kubernetes.default.svc
          namespace: netflux
        syncPolicy:
          automated:
            prune: true
            selfHeal: true
          syncOptions:
            - CreateNamespace=true
      YAML
    EOF
  }

  # 저장소 자격증명 Secret이 먼저 생성된 후 Application 생성
  depends_on = [kubernetes_secret_v1.argocd_repo_secret]
}
