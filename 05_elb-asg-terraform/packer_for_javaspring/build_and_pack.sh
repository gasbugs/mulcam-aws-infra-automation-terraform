#!/bin/bash

# 에러 발생 시 파이프라인 중단(Fail-fast)
set -e

# Docker 또는 Podman 자동 감지
if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
else
    echo "❌ 에러: 시스템에 Docker 또는 Podman이 설치되어 있지 않습니다."
    exit 1
fi

echo "=========================================================="
echo " [Step 1] ${CONTAINER_CMD} 컨테이너를 이용한 격리된(Isolated) 환경 빌드 "
echo "=========================================================="
# 호스트의 디렉토리를 /workspace에 마운트하여 로컬 환경에 독립적인 일관적 빌드 환경 구축
$CONTAINER_CMD run --rm \
  -v "$(pwd)":/workspace \
  -w /workspace \
  maven:3.9.6-eclipse-temurin-17 \
  mvn clean package

echo ""
echo "=========================================================="
echo " [Step 2] Packer 빌드(Baking) 실행 "
echo "=========================================================="
# 어차피 target 폴더에 .jar 파일이 생성되었기 때문에, 베이킹 과정은 기존 Packer를 활용
packer init spring-app.pkr.hcl
packer build spring-app.pkr.hcl

echo ""
echo "=========================================================="
echo " ✅ 모든 과정 완료: AMI 프로비저닝(굽기) 성공! "
echo "=========================================================="
