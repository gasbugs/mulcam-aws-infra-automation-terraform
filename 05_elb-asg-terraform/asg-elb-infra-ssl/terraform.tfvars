# AWS Provider
aws_region        = "us-east-1"
aws_profile       = "my-profile"
pub_key_file_path = "~/.ssh/my-key.pub"

# 오토 스케일링 그룹의 원하는 설정
instance_type    = "t2.micro"
desired_capacity = 2
max_size         = 4
min_size         = 2

# certs
private_key_file_path      = "./certs/private-key.pem"
certificate_body_file_path = "./certs/certificate.pem"
# certificate_chain_file_path= ""
