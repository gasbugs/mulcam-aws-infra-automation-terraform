#######################################
# DynamoDB 정보
resource "aws_dynamodb_table" "users_table" {
  name = var.table_name

  # 요금제를 선택 고정된 읽기와 쓰기가 가능하게 하려면 
  # billing 모드를  PROVISIONED 로 하고, read, write_capacity를 활성화하고
  # 요청당 비용을 측정하게 하려면 billing 모드를 PAY_PER_REQUEST로 설정한다. 
  billing_mode = "PAY_PER_REQUEST"
  # read_capacity  = var.read_capacity
  # write_capacity = var.write_capacity
  hash_key  = "UserId"
  range_key = "CreatedAt" # 테이블의 정렬 키로 사용할 속성 추가 (해시 키와 결합)


  attribute {
    name = "UserId"
    type = "S" # String 타입
  }

  attribute {
    name = "CreatedAt"
    type = "S" # 'CreatedAt'은 문자열(String) 타입으로 정렬 키에 사용
  }

  # 글로벌 보조 인덱스 설정 (Global Secondary Index)
  global_secondary_index {
    name            = "UsernameIndex" # 인덱스의 이름 설정
    hash_key        = "Username"      # 인덱스의 해시 키로 사용할 속성
    projection_type = "ALL"           # 인덱스에서 모든 테이블 속성을 가져오도록 설정
  }

  attribute {
    name = "Username"
    type = "S" # 'Username'은 문자열(String) 타입으로 보조 인덱스의 해시 키에 사용
  }
}
