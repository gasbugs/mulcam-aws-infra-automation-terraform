output "rds_endpoint" {
  description = "The endpoint of the RDS instance"
  value       = aws_db_instance.my_rds_instance.endpoint
}


output "rds_endpoint_read_replica" {
  description = "The endpoint of the RDS instance"
  value       = aws_db_instance.read_replica.endpoint
}

output "rds_security_group_id" {
  description = "The ID of the security group attached to the RDS instance"
  value       = aws_security_group.rds_sg.id
}

output "vpc_id" {
  description = "The ID of the VPC created by the module"
  value       = module.vpc.vpc_id
}

output "public_subnets" {
  description = "The public subnets created by the module"
  value       = module.vpc.public_subnets
}

output "private_subnets" {
  description = "The private subnets created by the module"
  value       = module.vpc.private_subnets
}

output "public_dns" {
  description = "Public domain of the EC2 instance"
  value       = module.ec2.public_dns
}

