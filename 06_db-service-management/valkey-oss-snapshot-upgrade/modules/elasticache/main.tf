# ElastiCache 서브넷 그룹 — Redis 클러스터를 배포할 프라이빗 서브넷 지정
resource "aws_elasticache_subnet_group" "redis_subnet_group" {
  name       = "${var.project_name}-redis-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "${var.project_name}-redis-subnet-group"
  }
}

# Redis 보안 그룹 — Redis 포트(6379) 접근을 제어하는 방화벽 규칙 모음
resource "aws_security_group" "redis_sg" {
  name        = "${var.project_name}-redis-sg"
  description = "Security group for Redis"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-redis-sg"
  }
}

# Redis 포트 인바운드 허용 — 허용된 CIDR 목록에서 6379번 포트 접근 가능
resource "aws_vpc_security_group_ingress_rule" "redis_port" {
  for_each          = toset(var.allowed_cidr_blocks)
  security_group_id = aws_security_group.redis_sg.id
  cidr_ipv4         = each.value
  from_port         = 6379
  to_port           = 6379
  ip_protocol       = "tcp"
  description       = "Allow Redis port access"
}

# 모든 아웃바운드 트래픽 허용
resource "aws_vpc_security_group_egress_rule" "redis_all" {
  security_group_id = aws_security_group.redis_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # 모든 프로토콜 허용
  description       = "Allow all outbound traffic"
}

# ElastiCache Replication Group — Redis 엔진 기반 클러스터 생성
resource "aws_elasticache_replication_group" "redis_cluster" {
  replication_group_id = "${var.project_name}-valkey"
  description          = "Valkey replication group with sharding enabled"
  engine               = "valkey"
  node_type            = var.node_type
  num_cache_clusters   = var.num_cache_nodes
  parameter_group_name = var.parameter_group_name
  subnet_group_name    = aws_elasticache_subnet_group.redis_subnet_group.name
  security_group_ids   = [aws_security_group.redis_sg.id]

  # 유지보수 및 스냅샷 시간 설정
  maintenance_window       = "tue:06:30-tue:07:30"
  snapshot_window          = "01:00-02:00" # 스냅샷 생성 시간 (UTC)
  snapshot_retention_limit = 7             # 스냅샷 보관 기간 (7일)
  # snapshot_name           = "my-redis-snapshot" # 스냅샷으로부터 복원 시 활성화 (변경하면 클러스터 재생성)

  # 설정 변경 즉시 적용 여부
  apply_immediately = true

  # 전송 중 암호화(TLS) 활성화
  transit_encryption_enabled = true

  # 저장 데이터 암호화 활성화
  at_rest_encryption_enabled = true

  auth_token                 = var.redis_auth_token  # 변수로 주입받은 인증 토큰 사용
  auth_token_update_strategy = "SET"

  tags = {
    Name = "${var.project_name}-redis-cluster"
  }
}
