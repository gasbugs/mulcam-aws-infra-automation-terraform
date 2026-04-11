provider "aws" {
  region  = var.aws_region
  profile = "my-profile"

  default_tags {
    tags = local.common_tags
  }
}
