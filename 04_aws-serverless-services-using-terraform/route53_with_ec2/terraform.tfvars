aws_region        = "us-east-1"                # 리소스를 배포할 AWS 리전
aws_profile       = "my-profile"               # 인증에 사용할 AWS CLI 프로파일
private_dns_name  = "test.private.example.com" # Private DNS의 도메인 이름
test_record_ip_1  = "10.0.0.11"                # 첫 번째 테스트 레코드가 가리킬 IP 주소
test_record_ip_2  = "10.0.0.12"                # 두 번째 테스트 레코드가 가리킬 IP 주소
instance_type     = "t3.micro"                 # EC2 인스턴스 유형
