# AWS Provider
aws_region  = "us-east-1"
aws_profile = "my-profile"

# 리소스 공통 태그
project     = "MarketingApp"
environment = "Production"
owner       = "TeamA"

# 오토 스케일링 그룹의 원하는 설정
instance_type    = "t3.micro"
desired_capacity = 2
max_size         = 4
min_size         = 2
