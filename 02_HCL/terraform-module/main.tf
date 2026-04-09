terraform {
  required_version = ">=1.13.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "my-profile"
}

# 모듈을 불어오는 기능
module "my_vpc" {
  source = "./modules/vpc" # 참조하려는 모듈의 위치

  # variables.tf에서 정의된 변수들에 값을 할당
  vpc_name   = "my-vpc"
  cidr_block = "10.0.0.0/16"
}
