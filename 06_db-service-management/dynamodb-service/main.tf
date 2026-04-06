#######################################
# DynamoDB 테이블 — 사용자 정보 저장
resource "aws_dynamodb_table" "users_table" {
  name = var.table_name

  # 요금제 설정
  # PROVISIONED: 고정된 읽기/쓰기 처리량을 미리 지정 (read_capacity, write_capacity 활성화 필요)
  # PAY_PER_REQUEST: 요청 건수만큼만 과금 — 트래픽이 불규칙하거나 학습 환경에 적합
  billing_mode = "PAY_PER_REQUEST"
  # read_capacity  = var.read_capacity
  # write_capacity = var.write_capacity

  hash_key  = "UserId"    # 파티션 키(Partition Key) — 데이터를 분산 저장하는 기준
  range_key = "CreatedAt" # 정렬 키(Sort Key) — 같은 파티션 내에서 데이터 정렬 기준

  attribute {
    name = "UserId"
    type = "S" # String 타입
  }

  attribute {
    name = "CreatedAt"
    type = "S" # String 타입 — ISO 8601 형식 문자열로 저장 (예: "2024-06-01T00:00:00")
  }

  # -----------------------------------------------------------------------
  # GSI(Global Secondary Index, 글로벌 보조 인덱스) — 나중에 실습 예정
  # -----------------------------------------------------------------------
  # 기본 키(UserId + CreatedAt) 외의 속성으로도 효율적인 쿼리를 가능하게 하는 기능.
  # 예) Username으로 사용자를 직접 검색하고 싶을 때 테이블 전체 스캔(Scan) 대신
  #     GSI를 통해 인덱스 조회(Query)로 빠르게 찾을 수 있다.
  #
  # 주요 옵션 설명:
  #   name            — 인덱스 이름 (쿼리 시 IndexName 파라미터에 지정)
  #   key_schema      — 이 인덱스의 파티션 키(HASH) / 정렬 키(RANGE) 설정
  #                     ※ GSI 내부에서는 hash_key/range_key가 만료됨 → key_schema 블록 사용
  #   projection_type — 인덱스에 복사할 속성 범위
  #                     ALL      : 모든 속성 복사 (조회 편리, 스토리지 비용↑)
  #                     KEYS_ONLY: 기본 키 + 인덱스 키만 복사 (최소 비용)
  #                     INCLUDE  : 지정한 속성만 추가 복사
  #
  # LSI(Local Secondary Index)와의 차이:
  #   GSI — 파티션 키가 달라도 됨, 테이블 생성 후에도 추가/삭제 가능
  #   LSI — 파티션 키가 기본 테이블과 동일해야 함, 테이블 생성 시에만 설정 가능
  # -----------------------------------------------------------------------
  # global_secondary_index {
  #   name            = "UsernameIndex" # 인덱스 이름 (쿼리 시 IndexName으로 참조)
  #   projection_type = "ALL"           # 모든 테이블 속성을 인덱스에 복사
  #
  #   key_schema {
  #     attribute_name = "Username"     # 이 인덱스의 파티션 키 — Username으로 직접 검색 가능
  #     key_type       = "HASH"
  #   }
  # }

  # GSI 활성화 시 아래 attribute 블록도 함께 주석 해제
  # attribute {
  #   name = "Username"
  #   type = "S" # 'Username'은 문자열(String) 타입으로 보조 인덱스의 해시 키에 사용
  # }

  tags = {
    Name = var.table_name # 테이블 이름 태그 — AWS 콘솔에서 리소스 식별에 사용
  }
}
