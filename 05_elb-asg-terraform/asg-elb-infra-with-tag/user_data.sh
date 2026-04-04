#!/bin/bash
yum install -y nginx # nginx 설치
systemctl enable nginx # 인스턴스 재부팅 시 nginx 자동 시작 등록
systemctl start nginx # nginx 즉시 시작
echo "Hello, Nginx! $(hostname)" > /usr/share/nginx/html/index.html # ALB 상태 확인용 인덱스 페이지 생성
