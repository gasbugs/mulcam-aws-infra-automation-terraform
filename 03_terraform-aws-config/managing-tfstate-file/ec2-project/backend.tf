# backend.tf

terraform {
  backend "s3" {
    bucket         = "my-terraform-state-bucket-nickname" # 상태 파일을 저장할 S3 버킷 이름
    key            = "ec2-project/dev/terraform.tfstate"  # 상태 파일의 경로 및 파일 이름
    region         = "us-east-1"                          # S3 버킷이 위치한 AWS 리전
    dynamodb_table = "terraform-state-lock-nickname"      # 상태 잠금을 위한 DynamoDB 테이블 이름
    encrypt        = true                                 # S3 버킷의 상태 파일을 암호화하여 저장
    profile        = "my-profile"                         # AWS CLI에서 사용할 프로필 이름
  }
}
