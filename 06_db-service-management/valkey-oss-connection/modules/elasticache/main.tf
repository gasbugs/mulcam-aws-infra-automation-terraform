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

# ElastiCache Replication Group — Valkey 엔진 기반 Redis 호환 클러스터 생성
resource "aws_elasticache_replication_group" "redis_cluster" {
  replication_group_id = "${var.project_name}-valkey"
  description          = "Redis replication group with sharding enabled"
  engine               = "valkey"
  node_type            = var.node_type
  parameter_group_name = var.parameter_group_name
  subnet_group_name    = aws_elasticache_subnet_group.redis_subnet_group.name
  security_group_ids   = [aws_security_group.redis_sg.id]

  # 클러스터 모드 비활성 시 필요한 아규먼트
  cluster_mode       = "disabled"
  num_cache_clusters = var.num_cache_nodes
  multi_az_enabled   = false # multi az를 활성화하려면 num_cache_clusters를 2개 이상으로 구성해야 함

  # 클러스터 모드 구성 시 필요한 아규먼트
  # cluster_mode            = "enabled"
  # num_node_groups         = 2 # 노드 그룹 수 = 샤드 수
  # replicas_per_node_group = 1 # 노드 그룹 당 복제본 수

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
