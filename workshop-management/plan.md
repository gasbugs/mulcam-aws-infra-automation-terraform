# awsw CLI — 구현 계획서

## 개요

`awsw`는 AWS 워크샵 운영에 필요한 계정 관리, 리소스 감사, 비용 모니터링 작업을
단일 CLI 도구로 통합한 툴이다. 동사·리소스 구분 없이 **목적 하나 = 커맨드 하나** 원칙을 따른다.

```
awsw <command> [flags]
```

---

## 커맨드 목록

| 커맨드 | 설명 | 기존 스크립트 |
|--------|------|-------------|
| `awsw setup` | 수강생 IAM 유저 생성 + 정책 연결 + CSV 출력 | `aws-workshop-setup.py` |
| `awsw teardown` | 수강생 IAM 유저 완전 삭제 | `aws-workshop-teardown.py` |
| `awsw audit` | 잔여 리소스 스캔 (읽기 전용) | `aws-resource-audit.py` |
| `awsw clean` | 잔여 리소스 스캔 후 삭제 | `aws-resource-audit.py --delete` |
| `awsw cost` | 전일 비용 리포트 (서비스별) | `aws-daily-cost-report.py` |
| `awsw check` | CloudFront / ALB 서비스 한도 점검 | `aws-limit-check.py` |
| `awsw tag` | Cost Allocation 태그 활성화 | `aws-activate-cost-tags.py` |
| `awsw admin` | terraform-user-0 어드민 권한 보장 | `aws-user-admin-setup.py` |
| `awsw status` | 각 계정의 유저/정책 연결 상태 조회 | 신규 |
| `awsw creds` | 생성된 크레덴셜 CSV 목록 및 내용 출력 | 신규 |
| `awsw pre` | 수업 전 준비 일괄 실행 (tag → admin → check) | 신규 |
| `awsw post` | 수업 후 정리 일괄 실행 (audit → clean → teardown) | 신규 |

---

## 수업 운영 흐름

```bash
# D-1 (수업 전날)
awsw tag       # Cost 태그 활성화 (24h 딜레이 있음)
awsw admin     # terraform-user-0 어드민 권한 확인
awsw check     # CloudFront / ALB 한도 점검
  → 또는: awsw pre

# D-Day (수업 당일)
awsw setup     # 수강생 계정 생성 + CSV 출력
awsw creds     # 생성된 크레덴셜 확인

# 수업 중
awsw status    # 계정 유저/정책 상태 확인
awsw audit     # 잔여 리소스 확인
awsw cost      # 비용 발생 여부 확인

# 수업 종료
awsw clean     # 잔여 리소스 정리
awsw teardown  # 수강생 계정 삭제
  → 또는: awsw post
```

---

## 공통 플래그

| 플래그 | 단축 | 설명 |
|--------|------|------|
| `--output [table\|json\|csv]` | `-o` | 출력 포맷 (기본값: `table`) |
| `--filter RANGE` | `-f` | 특정 계정만 처리 (예: `1-5`, `1,3,5`) |
| `--credentials-file PATH` | | accesskey.txt 경로 (기본값: `./accesskey.txt`) |
| `--dry-run` | | 실제 변경 없이 수행 결과 미리 보기 |
| `--yes` | `-y` | 삭제 작업의 확인 프롬프트 생략 |
| `--date YYYY-MM-DD` | | `cost` 커맨드에서 날짜 지정 |

---

## 파일 구조

```
workshop-management/
├── awsw.py              # 진입점 — click CLI, 커맨드 등록
├── commands/
│   ├── __init__.py
│   ├── setup.py         # awsw setup
│   ├── teardown.py      # awsw teardown
│   ├── audit.py         # awsw audit / clean
│   ├── cost.py          # awsw cost
│   ├── check.py         # awsw check
│   ├── tag.py           # awsw tag
│   ├── admin.py         # awsw admin
│   ├── status.py        # awsw status
│   ├── creds.py         # awsw creds
│   └── workflow.py      # awsw pre / post
└── utils/
    ├── __init__.py
    ├── credentials.py   # accesskey.txt 파싱 (공통)
    ├── session.py       # boto3 세션 생성 (공통)
    ├── output.py        # table / json / csv 출력 포맷터
    └── parallel.py      # concurrent.futures 병렬 처리 헬퍼
```

---

## 기술 스택

| 항목 | 선택 | 이유 |
|------|------|------|
| CLI 프레임워크 | `click` | 데코레이터 기반, flat 커맨드에 가장 간결 |
| 출력 포맷 | `rich` | 색상 테이블, 프로그레스바, 단계 출력 지원 |
| 병렬 처리 | `concurrent.futures` | 기존 스크립트와 동일한 방식 유지 |
| 패키징 | `pipx install .` | 어디서든 `awsw` 커맨드로 실행 가능 |

---

## 구현 우선순위

### Phase 1 — 기존 스크립트 통합
기존 스크립트 7개를 flat 커맨드로 래핑.

| 커맨드 | 기존 스크립트 |
|--------|-------------|
| `awsw setup` | `aws-workshop-setup.py` |
| `awsw teardown` | `aws-workshop-teardown.py` |
| `awsw audit` | `aws-resource-audit.py` |
| `awsw clean` | `aws-resource-audit.py --delete` |
| `awsw cost` | `aws-daily-cost-report.py` |
| `awsw check` | `aws-limit-check.py` |
| `awsw tag` | `aws-activate-cost-tags.py` |
| `awsw admin` | `aws-user-admin-setup.py` |

### Phase 2 — 공통 기반 강화
- `-o`, `-f`, `--dry-run`, `-y` 플래그
- `utils/` 공통 모듈로 중복 코드 제거 (각 스크립트마다 중복된 `parse_credentials`, `flush_log` 등)

### Phase 3 — 신규 기능 추가
- `awsw status` — 계정 유저/정책 상태 조회
- `awsw creds` — 크레덴셜 CSV 조회
- `awsw pre / post` — 워크플로우
- `awsw cost --date` — 날짜 지정 비용 조회

---

## 구현 시작 가이드

> 다음 대화에서 이어받을 수 있도록 작업 순서와 세부 내용을 기록한다.

### 중복 코드 현황 (utils/로 추출 대상)

7개 스크립트 모두에 아래 함수가 복사되어 있다. `utils/`로 한 번만 작성하고 import로 대체한다.

| 함수 | 위치 | 추출 대상 파일 |
|------|------|--------------|
| `parse_credentials()` | 전 스크립트 | `utils/credentials.py` |
| `flush_log()` | 전 스크립트 | `utils/output.py` |
| `get_account_id()` | 전 스크립트 | `utils/session.py` |
| `concurrent.futures` 병렬 패턴 | 전 스크립트 | `utils/parallel.py` |
| `record_result()` / `print_summary()` | 전 스크립트 | `utils/output.py` |

### Step 1 — utils/ 작성

#### `utils/credentials.py`
`accesskey.txt`를 파싱해 `(access_key, secret_key, account_name)` 리스트 반환.
`account_name`은 파일에 없으면 인덱스 기반으로 자동 생성 (`Account #1`, `Account #2`, ...).

```python
def load_credentials(file_path="accesskey.txt") -> list[dict]:
    # 반환: [{"access_key": ..., "secret_key": ..., "name": "Account #1"}, ...]
```

#### `utils/session.py`
boto3 세션 생성 및 계정 ID 조회.

```python
def make_session(access_key, secret_key) -> boto3.Session: ...
def get_account_id(session) -> str: ...
```

#### `utils/parallel.py`
`concurrent.futures.ThreadPoolExecutor` 래퍼. 각 커맨드에서 반복되는 병렬 처리 패턴을 하나로.

```python
def run_parallel(fn, credentials: list, max_workers=10) -> list:
    # credentials 리스트를 받아 fn(cred)를 병렬 실행, 결과 리스트 반환
```

#### `utils/output.py`
`rich` 기반 테이블 출력. `--output` 플래그에 따라 table / json / csv 전환.

```python
def print_table(results: list[dict], title: str): ...
def print_summary(results: list[dict]): ...
def format_output(results: list[dict], fmt: str): ...  # table | json | csv
```

### Step 2 — awsw.py 진입점

`click`으로 빈 CLI 골격을 먼저 만든다. 각 커맨드는 `commands/` 에서 import.

```python
# awsw.py
import click
from commands import setup, teardown, audit, clean, cost, check, tag, admin

@click.group()
def cli(): pass

cli.add_command(setup.cmd,    name="setup")
cli.add_command(teardown.cmd, name="teardown")
# ... 나머지 커맨드 등록

if __name__ == "__main__":
    cli()
```

`awsw --help` 가 동작하는 상태까지 확인 후 커맨드 래핑으로 진행.

### Step 3 — 커맨드 래핑 순서

아래 순서대로 진행한다. 앞쪽일수록 단순하고 의존성이 적다.

| 순서 | 커맨드 | 기존 스크립트 | 난이도 |
|------|--------|-------------|--------|
| 1 | `awsw setup` | `aws-workshop-setup.py` | 낮음 — 단방향 작업 |
| 2 | `awsw teardown` | `aws-workshop-teardown.py` | 낮음 — 단방향 작업 |
| 3 | `awsw cost` | `aws-daily-cost-report.py` | 낮음 — 읽기 전용 |
| 4 | `awsw check` | `aws-limit-check.py` | 낮음 — 읽기 전용 |
| 5 | `awsw tag` | `aws-activate-cost-tags.py` | 중간 — 임시 VPC 생성 |
| 6 | `awsw admin` | `aws-user-admin-setup.py` | 중간 |
| 7 | `awsw audit` | `aws-resource-audit.py` | 높음 — 27개 서비스 스캔 |
| 8 | `awsw clean` | `aws-resource-audit.py --delete` | 높음 — audit + 삭제 |

### Step 4 — 패키징 (`setup.py` 또는 `pyproject.toml`)

`pipx install .` 또는 `pip install -e .` 로 `awsw` 커맨드를 전역 등록.

```toml
# pyproject.toml
[project.scripts]
awsw = "awsw:cli"
```

### 의존성 패키지

```
boto3
click
rich
```

`requirements.txt` 또는 `pyproject.toml`의 `dependencies`에 추가.
