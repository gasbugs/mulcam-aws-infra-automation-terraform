# Terraform 및 프로바이더 버전 설정
terraform {
  required_version = ">= 1.13.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# AWS 프로바이더 설정
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}
