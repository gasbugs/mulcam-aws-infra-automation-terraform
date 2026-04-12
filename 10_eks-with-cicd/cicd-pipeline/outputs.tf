# CodeCommit 저장소 HTTPS 클론 URL (코드 push 시 사용)
output "codecommit_flask_example_url" {
  description = "flask-example 앱 소스 CodeCommit HTTPS URL"
  value       = aws_codecommit_repository.flask_example.clone_url_http
}

output "codecommit_flask_example_apps_url" {
  description = "flask-example-apps K8s 매니페스트 CodeCommit HTTPS URL"
  value       = aws_codecommit_repository.flask_example_apps.clone_url_http
}

# ECR 저장소 URL (buildspec.yml에서 이미지 푸시 대상으로 사용)
output "ecr_repository_url" {
  description = "Flask 앱 Docker 이미지를 저장할 ECR URL"
  value       = aws_ecr_repository.ecr_repo.repository_url
}

# ArgoCD 접속 주소 확인용
output "argocd_server_service" {
  description = "ArgoCD LoadBalancer 주소 확인 명령어"
  value       = "kubectl get svc -n argocd argocd-server"
}
