#!/bin/bash
# 빌드된 JAR 파일을 기반으로 Packer를 실행하여 AWS AMI를 굽는(Baking) 스크립트

# 에러 발생 시 즉시 중단 (Fail-fast)
set -e
set -o pipefail

# JAR 파일이 없으면 build.sh를 먼저 실행하도록 안내하고 중단
if [ ! -f "./target/demo-0.0.1-SNAPSHOT.jar" ]; then
    echo "에러: target/demo-0.0.1-SNAPSHOT.jar 파일이 없습니다. 먼저 build.sh를 실행하세요."
    exit 1
fi

echo "=========================================================="
echo " [Pack] Packer 빌드(Baking) 실행 "
echo "=========================================================="
# 플러그인 초기화 — 이미 초기화된 경우 자동으로 건너뜀
packer init spring-app.pkr.hcl
# 빌드 전 템플릿 문법 검증 — 오류를 사전에 잡아 불필요한 EC2 비용 방지
packer validate spring-app.pkr.hcl
packer build spring-app.pkr.hcl

echo ""
echo "=========================================================="
echo " Pack 완료: AMI 프로비저닝(굽기) 성공! "
echo "=========================================================="
