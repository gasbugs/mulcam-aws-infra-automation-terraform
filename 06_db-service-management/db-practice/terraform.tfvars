#######################################
# RDS에 대한 변수
aws_region           = "us-east-1"
aws_profile          = "my-profile"
vpc_cidr             = "10.0.0.0/16"
private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
public_subnet_cidrs  = ["10.0.3.0/24", "10.0.4.0/24"]
availability_zones   = ["a", "b"]
project_name         = "my-project"

# Elastic IPs for NAT Gateway
# elastic_ips = ["eipalloc-12345678", "eipalloc-87654321"]

#######################################
# DynamoDB에 대한 변수
dynamodb_table_name     = "Products"
dynamodb_hash_key       = "product_id"
dynamodb_hash_key_type  = "S"
dynamodb_billing_mode   = "PROVISIONED"
dynamodb_read_capacity  = 5
dynamodb_write_capacity = 5

#######################################
# Redis에 대한 변수
redis_allowed_cidr_blocks  = ["10.0.0.0/16"]
redis_auth_token           = "YourStrongAuthPassword123!"
redis_parameter_group_name = "default.valkey8.cluster.on"

#######################################
# EC2에 대한 변수
ec2_ami_id                  = "ami-0fff1b9a61dec8a5f"
ec2_instance_type           = "t2.micro"
ec2_public_key_path         = "~/.ssh/my-key.pub"
ec2_allowed_ssh_cidr_blocks = ["0.0.0.0/0"]

#######################################
# RDS에 대한 변수
# 접근 허용 CIDR
rds_mysql_allowed_cidr = "10.0.0.0/16"

# RDS 인스턴스 설정
rds_mysql_db_allocated_storage = 20
rds_mysql_db_engine_version    = "8.0.mysql_aurora.3.10.1"
rds_mysql_db_instance_class    = "db.t3.micro"
rds_mysql_db_name              = "mydatabase"

# RDS 보안 설정
rds_mysql_db_username = "admin"
rds_mysql_db_password = "securepassword123!" # 민감 정보, 환경 변수로도 관리 가능

# DB Parameter Group
rds_mysql_db_parameter_group_name = "default.mysql8.0"

# RDS 멀티 AZ 설정
rds_mysql_db_multi_az = true
