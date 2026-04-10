# Workshop Management CLI 리팩토링 설계

**날짜:** 2026-04-10  
**접근 방식:** 방식 B — 파일 분리 + 에러 처리 통일

---

## 1. 배경 및 목적

`workshop-management` 프로젝트는 AWS Terraform 워크샵 운영을 위한 CLI 도구입니다. 현재 다음 코드 품질 문제가 존재합니다:

- **`commands/clean.py` (1,963줄)**: 35개 리소스 삭제 함수가 단일 파일에 집중되어 유지보수 어려움
- **중복 상수**: `EXPECTED_IAM_USERS`, 스냅샷 경로 등이 `audit.py`와 `clean.py`에 각각 정의됨
- **중복 저수준 IAM 헬퍼**: 정책 분리, 인라인 정책 삭제 등의 패턴이 `teardown.py`와 `clean.py`에 중복
- **반복 에러 처리**: 35개 cleanup 함수마다 동일한 `try/except ClientError` 패턴 반복

이번 리팩토링은 **로직 변경 없이** 코드 구조를 개선하여 유지보수성을 향상시키는 것이 목적입니다.

---

## 2. 변경 범위

### 새로 생성되는 파일

| 파일 | 목적 |
|------|------|
| `commands/cleaners/__init__.py` | cleaners 패키지 마커 + 공개 인터페이스 |
| `commands/cleaners/iam.py` | IAM 역할/정책 삭제 (학생이 만든 IAM 리소스) |
| `commands/cleaners/compute.py` | EC2, AMI, EBS 스냅샷, ECS, Lambda, ASG, EKS |
| `commands/cleaners/network.py` | VPC, ALB/NLB, CloudFront, Route53 |
| `commands/cleaners/storage.py` | S3, EFS, RDS/Aurora 스냅샷 |
| `commands/cleaners/database.py` | RDS 인스턴스, Aurora 클러스터, DynamoDB, ElastiCache |
| `commands/cleaners/misc.py` | ImageBuilder, CodePipeline, ACM, CloudWatch Logs, Secrets Manager, KMS |
| `utils/constants.py` | 공유 상수 (EXPECTED_IAM_USERS, 스냅샷 경로 등) |
| `utils/iam_helpers.py` | 저수준 IAM 조작 헬퍼 (teardown/cleaners 공용) |

### 변경되는 파일

| 파일 | 변경 내용 |
|------|---------|
| `commands/clean.py` | `cleaners/` import 오케스트레이터로 축소 (~100줄 목표) |
| `commands/audit.py` | 상수를 `utils/constants.py`에서 import |
| `commands/teardown.py` | 저수준 IAM 헬퍼를 `utils/iam_helpers.py`에서 import |

### 변경하지 않는 파일

- `commands/setup.py`, `commands/cost.py`, `commands/check.py`, `commands/tag.py`, `commands/admin.py`
- `utils/credentials.py`, `utils/session.py`, `utils/parallel.py`, `utils/output.py`
- `awsw.py`, 미구현 스텁 파일들 (`status.py`, `creds.py`, `workflow.py`)

---

## 3. 세부 설계

### 3-1. `utils/constants.py` — 공유 상수 추출

```python
# 워크샵 관리 계정에서 삭제 대상에서 제외할 기본 IAM 유저 목록
EXPECTED_IAM_USERS = {"terraform-user-0", "terraform-user-1"}

# 감사 스냅샷 저장 경로
SNAPSHOT_DIR = "snapshots"
AUDIT_SNAPSHOT_FILE = "snapshots/audit_snapshot.json"
CLEAN_HISTORY_FILE = "snapshots/clean_history.json"
```

**현재 중복 위치:**
- `EXPECTED_IAM_USERS`: `commands/audit.py`와 `commands/clean.py`에 각각 정의
- 스냅샷 경로: `commands/audit.py`의 `_get_snapshot_dir()`와 `commands/clean.py`에서 각각 구성

---

### 3-2. `utils/iam_helpers.py` — 저수준 IAM 헬퍼 추출

teardown.py와 cleaners/iam.py가 공통으로 필요한 저수준 IAM 조작 함수를 모읍니다.

```python
def detach_all_policies(iam_client, resource_type: str, resource_name: str, log: list) -> None:
    """IAM 리소스(유저 또는 역할)에서 관리형 정책을 모두 분리한다."""

def delete_inline_policies(iam_client, resource_type: str, resource_name: str, log: list) -> None:
    """IAM 리소스의 인라인 정책을 모두 삭제한다."""
```

**teardown.py와 cleaners/iam.py의 목적 차이:**
- `teardown.py`: IAM 유저(`terraform-user-1`) 계정 자체를 완전 삭제 (강의 종료 후 계정 회수)
- `cleaners/iam.py`: 학생들이 실습 중 만든 IAM 역할/정책 삭제 (일일 리소스 정리)

이 두 파일의 비즈니스 로직은 분리 유지하되, 정책 분리/삭제 같은 공통 저수준 작업만 `iam_helpers.py`로 추출합니다.

---

### 3-3. `@handle_cleanup_error` 데코레이터 — 에러 처리 통일

`utils/output.py` 또는 별도 `utils/decorators.py`에 추가합니다.

```python
def handle_cleanup_error(resource_name: str):
    """
    cleanup 함수에서 반복되는 boto3 ClientError 처리를 통일하는 데코레이터.
    오류 발생 시 log 리스트에 일관된 포맷으로 추가한다.
    """
    def decorator(func):
        @functools.wraps(func)
        def wrapper(session, resources, log, *args, **kwargs):
            try:
                return func(session, resources, log, *args, **kwargs)
            except ClientError as e:
                log.append(f"  [오류] {resource_name} 삭제 실패: {e.response['Error']['Message']}")
        return wrapper
    return decorator
```

**적용 대상**: `cleaners/` 내 35개 `_perform_*_cleanup()` 함수

---

### 3-4. `commands/clean.py` 축소 — 오케스트레이터로 변환

```python
# 변경 전 (1,963줄): 모든 cleanup 함수가 이 파일에 직접 구현
# 변경 후 (~100줄): cleaners/ 서브모듈에서 import하여 순서 조율만 담당

from commands.cleaners.iam import perform_iam_cleanup
from commands.cleaners.compute import perform_compute_cleanup
from commands.cleaners.network import perform_network_cleanup
from commands.cleaners.storage import perform_storage_cleanup
from commands.cleaners.database import perform_database_cleanup
from commands.cleaners.misc import perform_misc_cleanup
```

---

### 3-5. `commands/cleaners/` 서브모듈 리소스 분배

| 모듈 | 담당 리소스 타입 |
|------|--------------|
| `iam.py` | IAM 역할, IAM 정책 (학생 생성 리소스) |
| `compute.py` | EC2 인스턴스, AMI 이미지, EBS 스냅샷, ECS 서비스/클러스터/태스크 정의, Lambda 함수, Auto Scaling 그룹, EKS 클러스터 |
| `network.py` | VPC (서브넷/IGW/NAT/라우팅 테이블/보안 그룹 포함), ALB/NLB, CloudFront 배포, Route53 레코드 |
| `storage.py` | S3 버킷, EFS 파일 시스템, RDS 스냅샷, Aurora 스냅샷 |
| `database.py` | RDS 인스턴스, Aurora 클러스터, DynamoDB 테이블, ElastiCache 클러스터 |
| `misc.py` | Image Builder, CodePipeline, ACM 인증서, CloudWatch Log 그룹, Secrets Manager, KMS 키 |

---

## 4. 파일 구조 변화

### 변경 전
```
commands/
  clean.py     ← 1,963줄 (35개 함수 모두 포함)
  audit.py     ← EXPECTED_IAM_USERS 상수 포함
  teardown.py  ← 저수준 IAM 헬퍼 포함

utils/
  credentials.py
  session.py
  parallel.py
  output.py
```

### 변경 후
```
commands/
  clean.py          ← ~100줄 (오케스트레이터)
  cleaners/
    __init__.py
    iam.py            ← IAM 리소스 정리
    compute.py        ← EC2/ECS/Lambda/EKS 등
    network.py        ← VPC/ALB/CloudFront 등
    storage.py        ← S3/EFS/스냅샷 등
    database.py       ← RDS/DynamoDB/ElastiCache
    misc.py           ← 기타 리소스
  audit.py          ← utils/constants.py 참조
  teardown.py       ← utils/iam_helpers.py 참조

utils/
  credentials.py
  session.py
  parallel.py
  output.py
  constants.py      ← 신규: 공유 상수
  iam_helpers.py    ← 신규: 저수준 IAM 헬퍼
```

---

## 5. 검증 방법

1. **단위 검증 (수동)**
   - `python -m awsw --help` 실행 → 모든 커맨드 목록 정상 출력 확인
   - `python -m awsw audit --help` 등 각 서브커맨드 옵션 확인

2. **import 검증**
   - `python -c "from commands import clean, audit, teardown"` 에러 없음 확인
   - `python -c "from utils import constants, iam_helpers"` 에러 없음 확인

3. **기능 검증 (드라이런)**
   - `awsw audit --credentials-file accesskey.txt` 실행하여 실제 스캔 동작 확인
   - 로그 출력 포맷이 리팩토링 전과 동일한지 확인

4. **회귀 방지**
   - `awsw clean --dry-run` (또는 mock 환경)에서 리소스 삭제 순서가 동일한지 확인
   - 에러 메시지 포맷이 변경되지 않았는지 확인

---

## 6. 리스크 및 완화 방안

| 리스크 | 완화 방안 |
|--------|---------|
| import 경로 변경으로 `awsw.py` 호환성 깨짐 | `cleaners/__init__.py`에서 공개 인터페이스를 re-export하여 clean.py의 내부 인터페이스만 변경 |
| 함수 이동 중 로직 누락 | 각 cleanup 함수를 1:1 이동 (리팩토링 없이 복붙), 데코레이터는 이동 후 적용 |
| 에러 메시지 포맷 변화 | 데코레이터의 오류 메시지 포맷을 기존 코드와 동일하게 맞춤 |
