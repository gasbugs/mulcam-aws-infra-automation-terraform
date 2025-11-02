resource "aws_dynamodb_table" "movies" {
  name           = "Movies"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "title"
  range_key      = "year"

  attribute {
    name = "title"
    type = "S"
  }

  attribute {
    name = "year"
    type = "N"
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id       = module.vpc.vpc_id
  service_name = "com.amazonaws.${var.aws_region}.dynamodb"

  vpc_endpoint_type  = "Interface"
  security_group_ids = [aws_security_group.allow_dynamodb.id]
  # vpc_endpoint_type  = "Gateway"
  # route_table_ids    = module.vpc.private_route_table_ids
  tags = {
    Name = "dynamodb-vpc-endpoint"
  }
}

resource "aws_security_group" "allow_dynamodb" {
  name        = "allow_dynamodb"
  description = "Allow DynamoDB traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_dynamodb"
  }
}
