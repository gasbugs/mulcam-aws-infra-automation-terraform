# dynamodb-service

Terraform으로 Amazon DynamoDB 테이블을 생성하고, Python(boto3)으로 기본 CRUD 및 GSI 조회를 실습하는 프로젝트입니다.  
NoSQL 데이터베이스인 DynamoDB의 키 구조와 인덱스 설계를 이해하고, 실제 데이터를 읽고 쓰는 전체 흐름을 익히는 것을 목표로 합니다.

## 학습 목표

- DynamoDB 테이블의 파티션 키(Hash Key)와 정렬 키(Range Key) 개념을 이해한다
- 과금 방식(`PAY_PER_REQUEST` vs `PROVISIONED`)의 차이를 이해한다
- Python boto3로 DynamoDB에 데이터를 쓰고(PutItem) 읽는(Query) 기본 흐름을 실습한다
- GSI(Global Secondary Index)를 추가해 기본 키 외 속성으로 쿼리하는 방법을 실습한다

## 아키텍처

```
DynamoDB Table: Users
├── Partition Key: UserId (String)
├── Sort Key:      CreatedAt (String)
└── GSI: UsernameIndex          ← 2단계에서 활성화
    └── Partition Key: Username (String)
```

## 사전 요구사항

| 항목 | 버전 / 값 |
|---|---|
| Terraform | >= 1.13.4 |
| AWS Provider | ~> 6.0 |
| Python | >= 3.10 |
| boto3 | `pip install boto3` |
| AWS CLI 프로파일 | `my-profile` (`~/.aws/config` 설정 필요) |
| AWS 리전 | `us-east-1` |

## 프로젝트 구조

```
dynamodb-service/
├── main.tf                   # DynamoDB 테이블 리소스 정의
├── variables.tf              # 입력 변수 선언
├── outputs.tf                # 출력값 (테이블 이름, ARN)
├── provider.tf               # AWS 프로바이더 및 Terraform 버전 설정
├── terraform.tfvars          # 변수값 설정
├── dynamo_connect_basic.py   # 기본 실습 — PutItem, Query
├── dynamo_connect_advanced.py# 심화 실습 — Range Key 조회, GSI 조회, UpdateItem, DeleteItem
└── README.md                 # 실습 가이드 (이 파일)
```

## 주요 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `table_name` | `Users` | DynamoDB 테이블 이름 |
| `read_capacity` | `5` | 읽기 처리량 (PROVISIONED 모드 전환 시 사용) |
| `write_capacity` | `5` | 쓰기 처리량 (PROVISIONED 모드 전환 시 사용) |

---

## 핵심 개념

### DynamoDB 키 구조

| 키 종류 | Terraform 속성 | 역할 |
|---|---|---|
| 파티션 키 (Partition Key) | `hash_key` | 데이터를 분산 저장하는 기준. 반드시 지정 |
| 정렬 키 (Sort Key) | `range_key` | 같은 파티션 내 데이터 정렬 기준. 선택 사항 |

이 프로젝트의 기본 키: **`UserId`(파티션) + `CreatedAt`(정렬)**

### 과금 방식

| 모드 | 설명 | 적합한 상황 |
|---|---|---|
| `PAY_PER_REQUEST` | 요청 건수만큼 과금, 용량 미리 지정 불필요 | 트래픽이 불규칙하거나 학습 환경 |
| `PROVISIONED` | 읽기/쓰기 처리량을 미리 지정, 예측 가능한 비용 | 일정한 트래픽의 운영 환경 |

### GSI (Global Secondary Index)

기본 키가 아닌 속성(예: `Username`)으로 효율적인 조회를 가능하게 하는 보조 인덱스.  
테이블 전체를 스캔(Scan)하는 대신 인덱스를 통해 빠르게 Query할 수 있다.

| 항목 | GSI | LSI |
|---|---|---|
| 파티션 키 | 기본 테이블과 달라도 됨 | 기본 테이블과 동일해야 함 |
| 생성 시점 | 테이블 생성 후에도 추가/삭제 가능 | 테이블 생성 시에만 설정 가능 |

---

## 실습 순서

### 1단계 — 기본 테이블 배포 및 CRUD 실습

**배포**

```bash
cd 06_db-service-management/dynamodb-service
terraform init
terraform apply
```

**기본 실습 실행** (`dynamo_connect_basic.py`)

```bash
AWS_PROFILE=my-profile python3 dynamo_connect_basic.py
```

실습 내용:
- `PutItem` — 사용자 데이터 2건 입력 (user1, user2)
- `Query` — `UserId`로 데이터 조회

---

### 2단계 — GSI 활성화 및 심화 실습

`main.tf`에서 GSI 블록과 `Username` attribute 블록의 주석을 해제합니다.

```hcl
# 아래 두 블록의 주석을 함께 해제
global_secondary_index {
  name            = "UsernameIndex"
  projection_type = "ALL"

  # GSI 내부에서는 hash_key/range_key가 만료됨 → key_schema 블록 사용
  key_schema {
    attribute_name = "Username"
    key_type       = "HASH"
  }
}

attribute {
  name = "Username"
  type = "S"
}
```

**재배포**

```bash
terraform apply
```

**심화 실습 실행** (`dynamo_connect_advanced.py`)

```bash
AWS_PROFILE=my-profile python3 dynamo_connect_advanced.py
```

실습 내용:
- `PutItem` — `Username` 포함한 사용자 데이터 입력
- `Query (Range Key)` — `UserId` + `CreatedAt` 범위 조건으로 데이터 조회
- `Query (GSI)` — `UsernameIndex`를 통해 `Username`으로 직접 조회
- `UpdateItem` — 특정 항목의 속성 값 업데이트
- `DeleteItem` — 특정 항목 삭제 후 결과 확인

---

### 3단계 — 리소스 정리

```bash
terraform destroy
```

---

## 출력값

| 출력 | 설명 |
|---|---|
| `dynamodb_table_name` | 생성된 테이블 이름 |
| `dynamodb_table_arn` | 테이블 ARN (IAM 정책 등에서 참조) |
