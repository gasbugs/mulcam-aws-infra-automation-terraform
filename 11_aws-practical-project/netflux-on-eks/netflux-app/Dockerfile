# 공식 Python 런타임을 부모 이미지로 사용
FROM python:3.12-slim

# 작업 디렉토리 설정
WORKDIR /app

# 현재 디렉토리의 내용을 컨테이너의 /app에 복사
COPY source /app

# 필요한 패키지 설치
RUN pip install --no-cache-dir flask boto3

# 환경 변수 설정 (기본값 제공, 실행 시 오버라이드 가능)
ENV DYNAMODB_TABLE="Movies"
ENV AWS_REGION="us-east-1"

# 포트 5000번을 외부에 노출
EXPOSE 5000

# 컨테이너 실행 시 실행할 명령
CMD ["python", "app.py"]
