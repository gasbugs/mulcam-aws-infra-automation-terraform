#!/bin/bash
# Spring Boot 소스 코드를 CodeCommit 저장소에 최초 push하는 헬퍼 스크립트
# terraform apply 완료 후 한 번만 실행하면 됨

set -e
set -o pipefail

# terraform output에서 CodeCommit URL 조회
CLONE_URL=$(terraform output -raw codecommit_clone_url_http 2>/dev/null)
if [ -z "$CLONE_URL" ]; then
  echo "오류: terraform output에서 codecommit_clone_url_http를 가져올 수 없습니다."
  echo "먼저 terraform apply를 실행해 주세요."
  exit 1
fi

echo "=================================================="
echo " CodeCommit URL: $CLONE_URL"
echo "=================================================="

# 소스 디렉토리로 이동 (packer-for-javaspring)
SOURCE_DIR="$(dirname "$0")/../packer-for-javaspring"
cd "$SOURCE_DIR"

# git 자격증명 도우미 설정 — IAM 프로파일(my-profile)로 CodeCommit 인증
git config --global credential.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true

# 이미 git 저장소인 경우 remote만 추가, 아닌 경우 새로 초기화
if [ -d ".git" ]; then
  echo "[INFO] 기존 git 저장소 감지 — remote를 codecommit으로 추가합니다"
  git remote remove codecommit 2>/dev/null || true
  git remote add codecommit "$CLONE_URL"
else
  echo "[INFO] git 저장소 초기화"
  git init
  git remote add codecommit "$CLONE_URL"
fi

# 빌드 산출물과 Packer 파일은 제외하고 Spring Boot 소스만 추가
git add pom.xml src/
git status

echo ""
read -p "위 파일들을 CodeCommit에 push하시겠습니까? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "취소되었습니다."
  exit 0
fi

# 커밋 후 push
git commit -m "feat: initial Spring Boot source upload for Image Builder" 2>/dev/null || \
  echo "[INFO] 변경 사항 없음 — 기존 커밋을 push합니다"

git push codecommit HEAD:main

echo ""
echo "=================================================="
echo " 소스 코드가 CodeCommit에 성공적으로 push되었습니다!"
echo " 이제 Image Builder 파이프라인을 실행할 수 있습니다:"
echo ""
echo "  $(cd "$(dirname "$0")" && terraform output -raw start_pipeline_command)"
echo "=================================================="
