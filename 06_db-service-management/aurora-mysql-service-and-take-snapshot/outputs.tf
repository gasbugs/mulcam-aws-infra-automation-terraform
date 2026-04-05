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

# Aurora 클러스터 ARN (Amazon Resource Name — AWS 리소스 고유 식별자)
output "aurora_cluster_arn" {
  description = "The ARN of the Aurora cluster"
  value       = aws_rds_cluster.my_aurora_cluster.arn
}

# 생성된 VPC의 ID
output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

# 퍼블릭 서브넷 ID 목록
output "public_subnets" {
  description = "The public subnets"
  value       = module.vpc.public_subnets
}

# 프라이빗 서브넷 ID 목록
output "private_subnets" {
  description = "The private subnets"
  value       = module.vpc.private_subnets
}
