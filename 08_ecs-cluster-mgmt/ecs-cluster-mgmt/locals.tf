locals {
  common_tags = {
    ManagedBy = "Terraform"
    Project   = var.project_name
    Practice  = "ecs-cluster-mgmt"
  }

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24"]
  short_name      = substr(replace(var.project_name, "_", "-"), 0, 16)
}
