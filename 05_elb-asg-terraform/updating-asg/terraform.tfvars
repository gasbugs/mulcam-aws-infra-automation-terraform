# AWS Provider
aws_region  = "us-east-1"
aws_profile = "my-profile"

# 사용할 AMI ID
# [실습] 아래 두 줄의 주석을 해제하고 현재 활성 줄을 주석 처리하면 v1 → v2 롤링 업데이트 실습 가능
ami_id  = "ami-03d71e85d83066661" # packer를 통해 생성된 httpd-v1 이미지 지정
asg_tag = "httpd-v1-asg"

# ami_id  = "ami-00ab207d11c78951f" # packer를 통해 생성된 httpd-v2 이미지 지정
# asg_tag = "httpd-v2-asg"

# 오토 스케일링 그룹의 원하는 설정
instance_type    = "t3.micro"
desired_capacity = 2
max_size         = 4
min_size         = 1

# certs
private_key_file_path      = "./certs/private-key.pem"
certificate_body_file_path = "./certs/certificate.pem"
# certificate_chain_file_path= ""
