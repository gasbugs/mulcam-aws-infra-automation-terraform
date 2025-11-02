# Redis 클러스터의 ID를 출력
output "redis_cluster_id" {
  description = "ID of the Redis cluster"                          # 출력 변수에 대한 설명
  value       = aws_elasticache_replication_group.redis_cluster.id # 생성된 Redis 클러스터의 고유 ID
}

# Redis 클러스터의 엔드포인트 주소를 출력
output "redis_cluster_endpoint" {
  description = "Endpoint of the Redis cluster"                                          # 출력 변수에 대한 설명
  value       = aws_elasticache_replication_group.redis_cluster.primary_endpoint_address # 생성된 Redis 클러스터의 Primary 엔드포인트 주소 (읽기/쓰기에 사용)
}

# Redis 클러스터에 적용된 보안 그룹의 ID를 출력
output "redis_security_group_id" {
  description = "Security group ID of the Redis cluster" # 출력 변수에 대한 설명
  value       = aws_security_group.redis_sg.id           # 생성된 Redis 클러스터의 보안 그룹 ID
}
