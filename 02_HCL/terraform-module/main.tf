terraform {
  required_version = ">=1.13.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">=6.19.0"
    }
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "my-profile"
}

module "my_vpc" {
  source = "./modules/vpc"

  # variables
  vpc_name   = "my-vpc"
  cidr_block = "10.0.0.0/16"
}
