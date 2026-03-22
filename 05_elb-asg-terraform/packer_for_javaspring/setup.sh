#!/bin/bash

# 패키지 업데이트
sudo dnf update -y

# Java 17 설치 (Amazon Linux 2023)
sudo dnf install -y java-17-amazon-corretto

# 앱 디렉토리 생성
mkdir -p /home/ec2-user/app
sudo chown -R ec2-user:ec2-user /home/ec2-user/app
