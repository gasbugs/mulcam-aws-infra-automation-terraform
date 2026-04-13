#!/bin/bash
# EC2 첫 부팅 시 자동 실행되는 초기화 스크립트
# Docker를 설치하고 서비스를 시작하며, ec2-user가 바로 사용할 수 있도록 설정

set -euo pipefail  # 오류 발생 시 스크립트 즉시 종료

# 시스템 패키지 최신화
dnf update -y

# Docker 설치 — AL2023 공식 저장소에서 제공하는 docker 패키지 사용
dnf install -y docker

# Docker 서비스 활성화 및 즉시 시작
# enable: 재부팅 후에도 자동 시작
# start: 지금 바로 시작
systemctl enable docker
systemctl start docker

# ec2-user를 docker 그룹에 추가 — sudo 없이 docker 명령어 실행 가능
usermod -aG docker ec2-user

# docker compose 플러그인 설치 — 멀티 컨테이너 실습에 활용
dnf install -y docker-compose-plugin

# 설치 결과 로그에 기록 (cloud-init 로그: /var/log/cloud-init-output.log)
echo "Docker installation completed: $(docker --version)"
echo "Docker service status: $(systemctl is-active docker)"
