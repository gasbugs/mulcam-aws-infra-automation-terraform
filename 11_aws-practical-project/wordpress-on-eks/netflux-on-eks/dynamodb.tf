# DynamoDB 테이블 생성 - 영화 정보(Movies)를 저장하는 NoSQL 데이터베이스
resource "aws_dynamodb_table" "movies" {
  name         = "Movies"
  billing_mode = "PROVISIONED" # 미리 읽기/쓰기 용량을 지정하는 방식 (교육 목적)
  read_capacity  = 5           # 초당 최대 읽기 요청 수
  write_capacity = 5           # 초당 최대 쓰기 요청 수
  hash_key     = "title"       # 파티션 키: 영화 제목
  range_key    = "year"        # 정렬 키: 출시 연도

  # 파티션 키 속성 정의 (S = String 문자열 타입)
  attribute {
    name = "title"
    type = "S"
  }

  # 정렬 키 속성 정의 (N = Number 숫자 타입)
  attribute {
    name = "year"
    type = "N"
  }

  tags = {
    Name = "movies-table"
  }
}

# DynamoDB VPC 엔드포인트 - VPC 내부에서 인터넷을 거치지 않고 DynamoDB에 안전하게 접근
# Interface 타입: VPC 내부에 네트워크 인터페이스를 생성하여 DynamoDB 연결 (Private DNS 지원)
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id       = module.vpc.vpc_id
  service_name = "com.amazonaws.${var.aws_region}.dynamodb"

  # Interface 타입: VPC 내에 실제 네트워크 인터페이스(ENI)를 생성하는 방식
  # Gateway 타입보다 비용이 발생하지만 Private DNS를 통해 투명하게 접근 가능
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets # 엔드포인트가 생성될 서브넷 (필수)
  security_group_ids  = [aws_security_group.allow_dynamodb.id]
  private_dns_enabled = true # VPC 내부에서 표준 DynamoDB 엔드포인트로 접근 가능하도록 DNS 설정

  tags = {
    Name = "dynamodb-vpc-endpoint"
  }
}

# DynamoDB VPC 엔드포인트에 대한 보안 그룹 (HTTPS 통신만 허용)
resource "aws_security_group" "allow_dynamodb" {
  name        = "allow-dynamodb-https"
  description = "Security group for DynamoDB VPC endpoint - allows HTTPS(443) from within VPC only"
  vpc_id      = module.vpc.vpc_id

  # VPC 내부에서만 HTTPS(443)로 DynamoDB 접근 허용 (외부 접근 차단)
  ingress {
    description = "Allow HTTPS from VPC for DynamoDB access"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # VPC CIDR 범위만 허용
  }

  # 모든 아웃바운드 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow-dynamodb-sg"
  }
}
