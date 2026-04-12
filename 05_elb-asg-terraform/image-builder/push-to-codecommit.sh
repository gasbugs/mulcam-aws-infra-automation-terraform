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

# Git Bash에서 user.name/user.email이 없으면 commit이 실패하므로 기본값을 보장
git config user.email 2>/dev/null | grep -q '@' || \
  git config user.email "terraform@example.com"
git config user.name 2>/dev/null | grep -qv '^$' || \
  git config user.name "Terraform"

# 커밋 후 push
# 주의: 2>/dev/null 로 에러를 숨기면 Git Bash에서 커밋 실패를 알 수 없어
#       HEAD가 unborn 상태인 채 push → "src refspec HEAD does not match any" 에러 발생
#       실제 에러는 출력하되, "nothing to commit" 메시지만 정상 처리
if git diff --cached --quiet 2>/dev/null && git log -1 2>/dev/null; then
  echo "[INFO] 변경 사항 없음 — 기존 커밋을 push합니다"
else
  git commit -m "feat: initial Spring Boot source upload for Image Builder"
fi

# HEAD가 실제 커밋을 가리키는지 확인 (초기화 직후 커밋 0개이면 push 불가)
if ! git rev-parse HEAD 2>/dev/null; then
  echo "오류: 커밋이 없습니다. 'git add' 후 파일이 staging됐는지 확인하세요."
  exit 1
fi

git push codecommit HEAD:main

echo ""
echo "=================================================="
echo " 소스 코드가 CodeCommit에 성공적으로 push되었습니다!"
echo " 이제 Image Builder 파이프라인을 실행할 수 있습니다:"
echo ""
echo "terraform output -raw start_pipeline_command"
echo "=================================================="
