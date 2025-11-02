# AWS 설정
aws_region  = "us-east-1"  # 원하는 AWS 리전 지정
aws_profile = "my-profile" # 사용할 AWS CLI 프로파일 이름 지정

# EC2 인스턴스 관련 설정
instance_type = "t2.micro"       # EC2 인스턴스 타입 지정
instance_name = "WebServer-Prod" # EC2 인스턴스 이름 지정

# 태그 관련 설정
environment = "Production"   # 배포 환경 지정
project     = "MarketingApp" # 프로젝트 이름 지정
owner       = "TeamA"        # 소유자 또는 담당 팀 지정
cost_center = "1234"         # 비용 센터 지정
