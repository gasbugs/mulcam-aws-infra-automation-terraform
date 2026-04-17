# ================================================================
# Terraform 출력값(Output)
#
# terraform apply 완료 후 화면에 출력되는 값들
# push_to_codecommit.sh 스크립트가 이 값들을 자동으로 읽어서 사용
# ================================================================

# javaspring 앱 소스 저장소 URL
# GitHub에서 클론한 소스 코드를 이 주소로 push하면 CI 파이프라인이 시작됨
output "codecommit_javaspring_url" {
  description = "javaspring 앱 소스 CodeCommit HTTPS URL"
  value       = aws_codecommit_repository.javaspring.clone_url_http
}

# javaspring-apps K8s 매니페스트 저장소 URL
# ArgoCD가 이 주소를 감시 → deployment.yaml 변경 시 EKS 자동 배포
output "codecommit_javaspring_apps_url" {
  description = "javaspring-apps K8s 매니페스트 CodeCommit HTTPS URL"
  value       = aws_codecommit_repository.javaspring_apps.clone_url_http
}

# ECR 저장소 URL
# CodeBuild가 빌드한 Docker 이미지를 이 주소에 push
# deployment.yaml의 image 필드에 이 주소:태그 형식으로 기록됨
output "ecr_repository_url" {
  description = "Java Spring Boot 앱 Docker 이미지를 저장할 ECR URL"
  value       = aws_ecr_repository.ecr_repo.repository_url
}

# ArgoCD 웹 UI 접속 주소 확인 명령어
# LoadBalancer External-IP가 할당되면 브라우저에서 ArgoCD 대시보드 접속 가능
# 초기 비밀번호: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
output "argocd_server_service" {
  description = "ArgoCD LoadBalancer 주소 확인 명령어"
  value       = "kubectl get svc -n argocd argocd-server"
}
