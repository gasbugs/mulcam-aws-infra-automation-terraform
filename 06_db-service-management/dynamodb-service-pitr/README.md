# dynamodb-service-pitr

Terraform으로 Amazon DynamoDB 테이블에 PITR(Point-In-Time Recovery)과 AWS Backup을 함께 구성하는 실습 프로젝트입니다.  
두 가지 백업 방식의 차이를 이해하고, 실제 백업 리소스를 배포·확인·정리하는 전체 흐름을 익히는 것을 목표로 합니다.

## 학습 목표

- PITR(Point-In-Time Recovery)과 AWS Backup의 차이를 이해한다
- AWS Backup Vault, Plan, Selection 리소스의 역할과 관계를 이해한다
- IAM 역할을 통해 AWS Backup 서비스에 권한을 부여하는 방법을 실습한다
- 복구 지점(Recovery Point)이 생성된 경우 수동 삭제 후 리소스를 정리하는 흐름을 익힌다

## 아키텍처

```
DynamoDB Table: Users
├── Partition Key: UserId (String)
├── Sort Key:      CreatedAt (String)
├── GSI: UsernameIndex
│   └── Partition Key: Username (String)
├── PITR: 활성화 (최대 35일 이내 특정 시점으로 복구 가능)
└── AWS Backup
    ├── Vault: dynamodb-backup-vault
    ├── Plan:  daily-dynamodb-backup (매시 40분 실행, 30일 보관)
    └── Selection: dynamodb-backup-selection (IAM Role: backup-role)
```

## 사전 요구사항

| 항목 | 버전 / 값 |
|---|---|
| Terraform | >= 1.13.4 |
| AWS Provider | ~> 6.0 |
| AWS CLI 프로파일 | `my-profile` (`~/.aws/config` 설정 필요) |
| AWS 리전 | `us-east-1` |

## 프로젝트 구조

```
dynamodb-service-pitr/
├── main.tf          # DynamoDB 테이블, AWS Backup 리소스 정의
├── variables.tf     # 입력 변수 선언
├── outputs.tf       # 출력값 (테이블 이름, ARN)
├── provider.tf      # AWS 프로바이더 및 Terraform 버전 설정
├── terraform.tfvars # 변수값 설정
└── README.md        # 실습 가이드 (이 파일)
```

## 주요 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `table_name` | `Users` | DynamoDB 테이블 이름 |

---

## 핵심 개념

### PITR vs AWS Backup

| 항목 | PITR | AWS Backup |
|---|---|---|
| 복구 단위 | 초 단위 특정 시점 | 스케줄 기반 스냅샷 |
| 보관 기간 | 최대 35일 (고정) | 직접 설정 가능 |
| 설정 위치 | DynamoDB 테이블 내 | 별도 Vault/Plan/Selection 리소스 |
| 비용 | 저장 용량 기준 과금 | 백업 용량 기준 과금 |
| 용도 | 실수로 인한 데이터 손상 즉시 복구 | 장기 보관, 정책 기반 백업 관리 |

### AWS Backup 구성 요소

| 리소스 | 역할 |
|---|---|
| Backup Vault | 백업 데이터(복구 지점)를 저장하는 컨테이너 |
| Backup Plan | 백업 주기, 보관 기간 등 정책 정의 |
| Backup Selection | 어떤 리소스를 백업할지 지정 (IAM Role 연결) |

---

## 실습 순서

### 1단계 — 리소스 배포

```bash
cd 06_db-service-management/dynamodb-service-pitr
terraform init
terraform apply
```

배포 후 AWS 콘솔에서 확인:
- **DynamoDB** → 테이블 `Users` → 백업 탭 → PITR 활성화 여부
- **AWS Backup** → Vault `dynamodb-backup-vault` → Plan, Selection 구성 확인

### 2단계 — 백업 실행 확인 (선택)

백업 스케줄은 `cron(40 * * * ? *)` (매시 40분, UTC)로 설정되어 있습니다.  
해당 시간까지 기다리면 복구 지점이 생성되는 것을 확인할 수 있습니다.

```bash
# Vault 내 복구 지점 목록 조회
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name dynamodb-backup-vault \
  --profile my-profile
```

### 3단계 — 리소스 정리

> **주의:** AWS Backup Vault는 복구 지점이 남아있으면 삭제되지 않습니다.  
> 백업이 한 번이라도 실행된 경우, 아래 절차로 복구 지점을 먼저 삭제해야 합니다.

**복구 지점이 있는 경우 수동 삭제:**

```bash
# 1. 복구 지점 ARN 목록 조회
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name dynamodb-backup-vault \
  --profile my-profile \
  --query 'RecoveryPoints[*].RecoveryPointArn' \
  --output text

# 2. 각 복구 지점 삭제 (RecoveryPointArn을 위 결과로 교체)
aws backup delete-recovery-point \
  --backup-vault-name dynamodb-backup-vault \
  --recovery-point-arn <RecoveryPointArn> \
  --profile my-profile
```

**Terraform으로 전체 삭제:**

```bash
terraform destroy
```

---

## 출력값

| 출력 | 설명 |
|---|---|
| `dynamodb_table_name` | 생성된 테이블 이름 |
| `dynamodb_table_arn` | 테이블 ARN (IAM 정책 등에서 참조) |
