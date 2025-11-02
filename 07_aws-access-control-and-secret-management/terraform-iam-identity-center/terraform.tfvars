aws_region  = "us-east-1"
aws_profile = "my-profile"

group_name        = "IMF"
user_given_name   = "Tom"
user_family_name  = "Cruise"
user_display_name = "MissonImpossible"
user_email        = "isc0304@naver.com"

# AWS CLI를 사용해 SSO 인스턴스의 ARN을 가져옴
# aws sso-admin list-instances --query 'Instances[0].InstanceArn' --output text
sso_instance_arn = "arn:aws:sso:::instance/ssoins-722317640e877a8d"

# Identity Store ID를 가져오기 위한 명령 실행
# aws sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text
identity_store_id = "d-9067d48ea9"
