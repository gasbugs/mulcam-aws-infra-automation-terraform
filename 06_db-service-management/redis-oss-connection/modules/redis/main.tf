# ElastiCache Subnet Group for Redis
resource "aws_elasticache_subnet_group" "redis_subnet_group" {
  name       = "${var.project_name}-redis-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "${var.project_name}-redis-subnet-group"
  }
}

# Security Group for Redis
resource "aws_security_group" "redis_sg" {
  name        = "${var.project_name}-redis-sg"
  description = "Security group for Redis"
  vpc_id      = var.vpc_id

  # Allow inbound traffic on the Redis port (6379) from the provided CIDR blocks
  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-redis-sg"
  }
}

# ElastiCache Cluster for Redis
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

  # Enable encryption in transit (TLS)
  transit_encryption_enabled = true

  # Optional: Enable encryption at rest
  at_rest_encryption_enabled = true

  auth_token                 = "YourStrongAuthPassword123!"
  auth_token_update_strategy = "SET"

  tags = {
    Name = "${var.project_name}-redis-cluster"
  }
}
