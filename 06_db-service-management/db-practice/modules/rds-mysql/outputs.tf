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
