sudo docker build -t netflux-app .
sudo docker run -d -p 5000:5000 --name netflux netflux-app
sudo docker logs netflux
sudo docker rm netflux -f
sudo docker rm `sudo docker ps -a -q` -f

# 환경 변수를 입력하여 동작하도록 설정
# 컨테이너 실행
sudo docker run -d -p 5000:5000 \
  -e DYNAMODB_TABLE=Movies \
  -e AWS_REGION=us-east-1 \
  -e AWS_ACCESS_KEY_ID='AWS_ACCESS_KEY_ID' \
  -e AWS_SECRET_ACCESS_KEY='AWS_SECRET_ACCESS_KEY' \
  --name netflux netflux-app

# aws cli 설치 
# sudo snap install aws-cli --classic

# DynamoDB 구성
aws dynamodb create-table \
    --table-name Movies \
    --attribute-definitions \
        AttributeName=title,AttributeType=S \
        AttributeName=year,AttributeType=N \
    --key-schema \
        AttributeName=title,KeyType=HASH \
        AttributeName=year,KeyType=RANGE \
    --provisioned-throughput \
        ReadCapacityUnits=5,WriteCapacityUnits=5 \
    --region us-east-1

# DynamoDB 삭제
aws dynamodb delete-table --table-name Movies
