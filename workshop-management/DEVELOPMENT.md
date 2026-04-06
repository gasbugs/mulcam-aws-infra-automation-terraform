# awsw — 개발자 가이드

이 문서는 `awsw` CLI의 내부 구조, 구현 히스토리, 확장 방법을 기록합니다.
사용법은 [README.md](README.md)를 참조하세요.

---

## 프로젝트 구조

```
workshop-management/
├── awsw.py                          # CLI 진입점 — click 커맨드 등록
├── commands/                        # 커맨드별 구현
│   ├── __init__.py
│   ├── setup.py                     # awsw setup
│   ├── teardown.py                  # awsw teardown
│   ├── audit.py                     # awsw audit / clean
│   ├── cost.py                      # awsw cost
│   ├── check.py                     # awsw check
│   ├── tag.py                       # awsw tag
│   ├── admin.py                     # awsw admin
│   ├── status.py                    # awsw status (스텁)
│   ├── creds.py                     # awsw creds (스텁)
│   └── workflow.py                  # awsw pre / post (스텁)
├── utils/                           # 공통 유틸리티
│   ├── __init__.py
│   ├── credentials.py               # accesskey.txt 파싱, 필터링
│   ├── session.py                   # boto3 세션 생성, 계정 ID 조회
│   ├── output.py                    # 로그 출력, 결과 수집, 포맷 변환
│   └── parallel.py                  # ThreadPoolExecutor 래퍼
├── terraform-resource-types.yaml    # 리포지토리 전체 Terraform 리소스 타입 목록
├── requirements.txt                 # 의존성 패키지
├── pyproject.toml                   # 패키지 메타데이터 (Python >= 3.10용)
└── setup.cfg                        # 패키지 메타데이터 (Python 3.9 setuptools 58용)
```

---

## 기술 스택

| 항목 | 선택 | 이유 |
|------|------|------|
| CLI 프레임워크 | `click` | 데코레이터 기반, flat 커맨드에 가장 간결 |
| 출력 포맷 | `rich` | 색상 테이블, 폴백 시 일반 print |
| 병렬 처리 | `concurrent.futures` | 기존 스크립트와 동일한 방식 유지 |
| 패키징 | `pip install .` | `awsw` 전역 커맨드 등록 |

---

## utils/ 모듈 설명

### `utils/credentials.py`

| 함수 | 설명 |
|------|------|
| `load_credentials(file_path)` | accesskey.txt 파싱 → `[{"access_key", "secret_key", "name"}]` 반환 |
| `filter_credentials(creds, filter_str)` | `"1-5"`, `"1,3,5"` 형식으로 계정 필터링 |

### `utils/session.py`

| 함수 | 설명 |
|------|------|
| `make_session(access_key, secret_key)` | boto3.Session 생성 |
| `get_account_id(session)` | STS로 계정 ID 조회, 실패 시 None |

### `utils/parallel.py`

| 함수 | 설명 |
|------|------|
| `run_parallel(fn, credentials, max_workers=10)` | `fn(cred: dict)` 를 병렬 실행, 결과 리스트 반환 |

`fn`은 cred dict 하나를 받아야 하며, 추가 인자는 `functools.partial`로 바인딩합니다.

```python
from functools import partial
run_parallel(partial(my_fn, extra_arg=value), creds)
```

### `utils/output.py`

| 함수/변수 | 설명 |
|-----------|------|
| `flush_log(lines)` | 스레드 안전 로그 출력 (병렬 처리 중 출력 섞임 방지) |
| `record_result(entry)` | 결과 dict를 모듈 레벨 리스트에 스레드 안전하게 추가 |
| `get_results()` | 수집된 결과 리스트 복사본 반환 |
| `clear_results()` | 결과 리스트 초기화 (커맨드 시작 시 호출) |
| `account_sort_key(entry)` | `entry["name"]`에서 계정 번호 추출 (정렬용) |
| `print_table(results, title)` | rich 또는 텍스트 테이블 출력 |
| `format_output(results, fmt, title)` | table / json / csv 포맷 출력 |

---

## 새 커맨드 추가 방법

1. `commands/my_cmd.py` 생성

```python
from __future__ import annotations  # Python 3.9 필수
import click
from utils.credentials import load_credentials, filter_credentials
from utils.output import flush_log, record_result, clear_results, get_results
from utils.parallel import run_parallel
from utils.session import make_session, get_account_id

def _process_account(cred: dict) -> None:
    # 계정별 처리 로직
    ...

@click.command()
@click.option("--credentials-file", default="accesskey.txt", show_default=True)
@click.option("--filter", "-f", "account_filter", default=None)
def cmd(credentials_file, account_filter):
    """커맨드 설명."""
    creds = filter_credentials(load_credentials(credentials_file), account_filter)
    clear_results()
    run_parallel(_process_account, creds)
```

2. `awsw.py`에 등록

```python
from commands import my_cmd
cli.add_command(my_cmd.cmd, name="my-cmd")
```

3. `pip install .` 재실행

---

## 환경 주의사항

- **Python 3.9** 환경입니다.
- `str | None`, `list[dict]` 등 Python 3.10+ 타입 힌트 문법을 사용하려면
  모든 파일 최상단에 `from __future__ import annotations`가 필요합니다.
- setuptools 58 환경으로, `pyproject.toml` 단독으로는 메타데이터 인식이 안 됩니다.
  `setup.cfg`가 실질적인 패키지 설정 파일입니다.
- 설치 경로: `/Users/gasbugs/Library/Python/3.9/bin/awsw` — PATH 등록 필요.

---

## terraform-resource-types.yaml

리포지토리 전체 `.tf` 파일에서 수집한 AWS 리소스 타입 목록입니다.
`awsw audit` / `awsw clean` 구현 시 이 파일을 참조합니다.

```python
import yaml

with open("terraform-resource-types.yaml") as f:
    data = yaml.safe_load(f)

# AWS 리소스 타입 flat 목록 (non_aws 제외)
aws_types = [r for cat in data["aws"].values() for r in cat]
```

수집 방법:
```bash
grep -rh '^resource "' --include="*.tf" --exclude-dir=".terraform" \
  | sed 's/resource "\([^"]*\)".*/\1/' | sort -u
```

---

## 구현 히스토리

### Phase 1 — 기존 스크립트 → awsw CLI 통합 ✅

기존 독립 Python 스크립트 7개를 `awsw` 단일 CLI로 래핑한 단계.

#### Step 1 — utils/ 공통 모듈 작성

기존 스크립트 7개에 복사되어 있던 공통 함수를 utils/로 추출.

| 기존 중복 함수 | 추출 위치 |
|--------------|----------|
| `parse_credentials()` | `utils/credentials.py` |
| `flush_log()`, `record_result()`, `print_summary()` | `utils/output.py` |
| `get_account_id()`, boto3.Session 생성 | `utils/session.py` |
| `ThreadPoolExecutor` 패턴 | `utils/parallel.py` |

#### Step 2 — awsw.py 진입점 + commands/ 스텁

- click 기반 CLI 골격 구성
- 12개 커맨드 스텁 등록 (`awsw --help` 동작 확인)

#### Step 3 — 커맨드 래핑

| 커맨드 | 기존 스크립트 | 특이사항 |
|--------|-------------|---------|
| `setup` | `aws-workshop-setup.py` | CSV 쓰기 스레드 안전 처리 |
| `teardown` | `aws-workshop-teardown.py` | 파괴적 작업 — `--yes` 없으면 확인 프롬프트 |
| `cost` | `aws-daily-cost-report.py` | `--date` 플래그 신규 추가 |
| `check` | `aws-limit-check.py` | CloudFront / ALB 실제 생성 시도 후 즉시 삭제 |
| `tag` | `aws-activate-cost-tags.py` | 임시 VPC 생성으로 CE 태그 등록 |
| `admin` | `aws-user-admin-setup.py` | terraform-user-0 AdministratorAccess 단독 보장 |
| `audit` | `aws-resource-audit.py` | 27개 서비스 × 전 리전 병렬 스캔 |
| `clean` | `aws-resource-audit.py --delete` | audit + IAM/CF/AMI/EBS/RDS/VPC 순서대로 정리 |

#### Step 4 — 패키징

- `pyproject.toml` + `setup.cfg` 구성 (setuptools 58 호환)
- `pip install .` 후 `awsw` 전역 커맨드 등록 확인

---

### Phase 2 — 공통 기반 강화 (미구현)

- `-o`, `-f`, `--dry-run`, `-y` 플래그 — Phase 1에서 이미 대부분 구현됨
- 기존 레거시 스크립트에 utils/ import 적용 (선택)

### Phase 3 — 신규 기능 (미구현, 스텁 상태)

| 커맨드 | 설명 |
|--------|------|
| `awsw status` | 각 계정의 IAM 유저/정책 연결 상태 조회 |
| `awsw creds` | 생성된 `workshop-credentials-*.csv` 목록 및 내용 출력 |
| `awsw pre` | tag → admin → check 순서 일괄 실행 |
| `awsw post` | audit → clean → teardown 순서 일괄 실행 |
