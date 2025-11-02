# Security Group for DynamoDB VPC Endpoint
resource "aws_security_group" "dynamodb_sg" {
  name        = "${var.project_name}-dynamodb-sg"
  description = "Security group for DynamoDB VPC Endpoint"
  vpc_id      = var.vpc_id

  # Allow all inbound traffic from private subnets (where EC2 is located)
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.private_subnet_cidrs
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-dynamodb-sg"
  }
}

# DynamoDB Table (unchanged)
resource "aws_dynamodb_table" "main_table" {
  name         = var.table_name
  billing_mode = var.billing_mode
  hash_key     = var.hash_key

  attribute {
    name = var.hash_key
    type = var.hash_key_type
  }

  # range_key와 관련된 설정이 있는 경우에만 추가
  dynamic "attribute" {
    for_each = var.range_key != null ? [var.range_key] : []
    content {
      name = var.range_key
      type = var.range_key_type
    }
  }

  range_key = var.range_key != null ? var.range_key : null

  # Provisioned throughput (if used)
  #read_capacity  = var.read_capacity
  #write_capacity = var.write_capacity

  tags = {
    Name = "${var.project_name}-dynamodb"
  }
}

# VPC Endpoint for DynamoDB
resource "aws_vpc_endpoint" "dynamodb_endpoint" {
  vpc_id             = var.vpc_id
  service_name       = "com.amazonaws.${var.region}.dynamodb"
  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.dynamodb_sg.id]

  vpc_endpoint_type = "Interface"

  tags = {
    Name = "${var.project_name}-dynamodb-endpoint"
  }
}

# IAM 역할 생성
resource "aws_iam_role" "ec2_dynamodb_role" {
  name = "EC2DynamoDBRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# DynamoDB 정책 생성
resource "aws_iam_policy" "dynamodb_access_policy" {
  name = "DynamoDBFullAccessPolicy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:*" # 모든 DynamoDB 작업을 허용
      ]
      Resource = "*"
    }]
  })
}

# IAM 역할과 정책 연결
resource "aws_iam_role_policy_attachment" "ec2_dynamodb_policy_attach" {
  role       = aws_iam_role.ec2_dynamodb_role.name
  policy_arn = aws_iam_policy.dynamodb_access_policy.arn
}

# 인스턴스 프로파일 생성
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "EC2DynamoDBInstanceProfile"
  role = aws_iam_role.ec2_dynamodb_role.name
}

