#!/bin/bash
# Spring Boot 앱을 컨테이너 환경에서 빌드하여 target/ 폴더에 JAR 파일을 생성하는 스크립트

# 에러 발생 시 즉시 중단 (Fail-fast)
set -e
set -o pipefail

# Docker 또는 Podman 자동 감지
if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
else
    echo "에러: 시스템에 Docker 또는 Podman이 설치되어 있지 않습니다."
    exit 1
fi

echo "=========================================================="
echo " [Build] ${CONTAINER_CMD} 컨테이너를 이용한 격리된(Isolated) 환경 빌드 "
echo "=========================================================="
# 호스트의 디렉토리를 /workspace에 마운트하여 로컬 환경에 독립적인 일관적 빌드 환경 구축
$CONTAINER_CMD run --rm \
  -v "$(pwd)":/workspace \
  -w /workspace \
  maven:3.9.6-eclipse-temurin-17 \
  mvn clean package

echo ""
echo "=========================================================="
echo " Build 완료: target/ 폴더에 JAR 파일 생성됨 "
echo "=========================================================="
