##############################################################################
# [codecommit.tf] 소스 코드 저장소
#
# AWS CodeCommit은 GitHub처럼 git을 사용할 수 있는 AWS 관리형 저장소입니다.
# 이 파일에서 정의하는 것:
#   - Spring Boot 소스 코드를 저장할 CodeCommit 저장소
#
# 역할 연결: Image Builder 빌드 인스턴스(components.tf)가
#            이 저장소에서 소스를 git clone하여 JAR를 빌드합니다.
##############################################################################

# CodeCommit 저장소 — Spring Boot 소스 코드를 관리하는 AWS 관리형 Git 저장소
# Image Builder 빌드 인스턴스가 여기서 소스를 clone하여 JAR를 직접 빌드함
resource "aws_codecommit_repository" "spring_app" {
  repository_name = var.codecommit_repo_name
  description     = "Spring Boot 애플리케이션 소스 코드 저장소 (Image Builder 연동)"

  tags = {
    Name        = var.codecommit_repo_name
    Environment = var.environment
  }
}
