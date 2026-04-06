# DynamoDB 테이블 생성 — 해시 키(필수)와 선택적 정렬 키로 구성
resource "aws_dynamodb_table" "main_table" {
  name         = var.table_name
  billing_mode = var.billing_mode
  hash_key     = var.hash_key

  attribute {
    name = var.hash_key
    type = var.hash_key_type
  }

  # range_key가 지정된 경우에만 정렬 키 속성을 동적으로 추가
  dynamic "attribute" {
    for_each = var.range_key != null ? [var.range_key] : []
    content {
      name = var.range_key
      type = var.range_key_type
    }
  }

  range_key = var.range_key != null ? var.range_key : null

  # PROVISIONED 모드 사용 시 활성화
  #read_capacity  = var.read_capacity
  #write_capacity = var.write_capacity

  tags = {
    Name = "${var.project_name}-dynamodb"
  }
}

# DynamoDB VPC Gateway 엔드포인트 — 프라이빗 서브넷에서 인터넷 없이 DynamoDB에 접근 가능
# Gateway 타입은 ENI 없이 라우팅 테이블 기반으로 동작하며 추가 비용이 없음
resource "aws_vpc_endpoint" "dynamodb_endpoint" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway" # Interface 대비 비용 없음, DynamoDB 표준 연결 방식

  route_table_ids = var.private_route_table_ids # 프라이빗 서브넷의 라우팅 테이블에 경로 자동 추가

  tags = {
    Name = "${var.project_name}-dynamodb-endpoint"
  }
}

# EC2가 DynamoDB에 접근할 수 있도록 IAM 역할 생성
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

# DynamoDB 접근 정책 생성
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

# 인스턴스 프로파일 생성 — EC2에 IAM 역할을 부여하는 컨테이너
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "EC2DynamoDBInstanceProfile"
  role = aws_iam_role.ec2_dynamodb_role.name
}
