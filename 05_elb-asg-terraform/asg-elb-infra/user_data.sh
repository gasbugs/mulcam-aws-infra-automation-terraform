#!/bin/bash
yum install -y nginx # nginx 설치
systemctl start nginx # nginx 시작
echo "Hello, Nginx! $(hostname)" > /usr/share/nginx/html/index.html # 인덱스 페이지 생성
