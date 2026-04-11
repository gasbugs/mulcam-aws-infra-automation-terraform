locals {
  common_tags = {
    ManagedBy = "Terraform"
    Project   = var.project_name
    Practice  = "ecr-pull-through-cache"
  }

  docker_hub_credentials_enabled = (
    var.docker_hub_username != null &&
    var.docker_hub_access_token != null
  )
}
