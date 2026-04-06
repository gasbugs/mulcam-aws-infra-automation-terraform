aws_region           = "us-east-1"
aws_profile          = "my-profile"
vpc_cidr             = "10.0.0.0/16"
private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
public_subnet_cidrs  = ["10.0.3.0/24", "10.0.4.0/24"]
availability_zones   = ["a", "b"]
project_name         = "my-project"

# Valkey settings
redis_allowed_cidr_blocks = ["10.0.0.0/16"]
redis_auth_token          = "YourStrongAuthPassword123!"

# [1단계] 초기 배포 — t3.micro로 시작
redis_node_type = "cache.t3.micro"
# [2단계] 노드 타입 업그레이드 — 아래 줄 활성화 후 위 줄 주석 처리
# redis_node_type = "cache.t3.medium"
