# Aurora 클러스터 엔드포인트 (읽기/쓰기)
output "aurora_cluster_endpoint" {
  description = "The endpoint to connect to the Aurora cluster"
  value       = aws_rds_cluster.my_aurora_cluster.endpoint
}

# Aurora 클러스터 포트
output "aurora_cluster_port" {
  description = "The port on which the Aurora cluster is listening"
  value       = aws_rds_cluster.my_aurora_cluster.port
}

# Aurora 클러스터의 읽기 전용 엔드포인트
output "aurora_cluster_reader_endpoint" {
  description = "The read-only endpoint for the Aurora cluster"
  value       = aws_rds_cluster.my_aurora_cluster.reader_endpoint
}

# Aurora 인스턴스의 ID
output "aurora_instance_id" {
  description = "The ID of the Aurora cluster instance"
  value       = aws_rds_cluster_instance.my_aurora_instance.id
}

# Aurora 클러스터 ARN (Amazon Resource Name)
output "aurora_cluster_arn" {
  description = "The ARN of the Aurora cluster"
  value       = aws_rds_cluster.my_aurora_cluster.arn
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

/*
output "public_dns" {
  description = "Public domain of the EC2 instance"
  value       = module.ec2.public_dns
}
*/
