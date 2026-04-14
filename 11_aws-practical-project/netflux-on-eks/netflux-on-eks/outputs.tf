# CloudFront 도메인 — 실제 사용자 접속 주소 (CLB와 S3로 트래픽 분산)
output "cloudfront_domain" {
  value       = "https://${aws_cloudfront_distribution.s3_distribution.domain_name}"
  description = "CloudFront 배포 도메인 (기본: CLB, *.jpg: S3)"
}

# CloudFront 접속 및 라우팅 검증 명령어
output "verify_commands" {
  value = <<-EOT
    # 1. CloudFront 메인 페이지 → CLB(Flask) 경유 확인
    curl -s -o /dev/null -w "Main page HTTP: %%{http_code}\n" https://${aws_cloudfront_distribution.s3_distribution.domain_name}/

    # 2. CloudFront .jpg 요청 → S3 경유 확인 (x-cache 헤더로 오리진 구분)
    curl -sI https://${aws_cloudfront_distribution.s3_distribution.domain_name}/static/sonic3_poster.jpg | grep -E "HTTP|x-cache|content-type|x-amz"
  EOT
  description = "CloudFront를 통한 CLB/S3 라우팅 검증 명령어"
}

# netflux-app 소스 코드를 올릴 CodeCommit 저장소 주소 (HTTPS)
output "netflux_app_codecommit_url" {
  value       = aws_codecommit_repository.netflux_app.clone_url_http
  description = "netflux-app 소스 코드를 push할 CodeCommit 저장소 HTTPS 주소"
}

# ArgoCD가 감시할 배포 매니페스트 저장소 주소 (HTTPS)
output "netflux_deploy_codecommit_url" {
  value       = aws_codecommit_repository.netflux_deploy.clone_url_http
  description = "ArgoCD가 연결할 netflux-deploy CodeCommit 저장소 HTTPS 주소"
}

# ECR 저장소 주소 — deployment.yaml 초기 설정 또는 확인용
output "ecr_repository_url" {
  value       = aws_ecr_repository.ecr_repo.repository_url
  description = "Docker 이미지가 저장되는 ECR 저장소 주소"
}

# ArgoCD 서버 접속 주소 확인 명령어 안내
output "argocd_access_command" {
  value       = "kubectl get svc argocd-server -n argocd"
  description = "ArgoCD 웹 UI 접속 주소를 확인하는 kubectl 명령어"
}

# netflux-app 코드를 CodeCommit에 push하는 명령어 안내
output "push_netflux_app_commands" {
  value = <<-EOT
    cd ../netflux-app
    git init && git add . && git commit -m "initial commit"
    git remote add origin ${aws_codecommit_repository.netflux_app.clone_url_http}
    git push -u origin main
  EOT
  description = "netflux-app 소스 코드를 CodeCommit에 push하는 명령어 (push하면 CI/CD 파이프라인 자동 실행)"
}

# netflux-deploy 매니페스트를 CodeCommit에 push하는 명령어 안내
output "push_netflux_deploy_commands" {
  value = <<-EOT
    cd ../netflux-deploy
    git init && git add . && git commit -m "initial commit"
    git remote add origin ${aws_codecommit_repository.netflux_deploy.clone_url_http}
    git push -u origin main
  EOT
  description = "netflux-deploy 매니페스트를 CodeCommit에 push하는 명령어 (ArgoCD가 이 저장소를 감시)"
}
