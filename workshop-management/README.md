# awsw — AWS 워크샵 운영 CLI

Terraform 워크샵 운영에 필요한 계정 관리, 리소스 감사, 비용 모니터링을 단일 CLI로 통합한 도구입니다.
`accesskey.txt`에 등록된 모든 루트 계정을 대상으로 병렬 처리합니다.

---

## 설치

```bash
cd workshop-management
pip install .
```

설치 후 어디서든 `awsw` 커맨드로 실행할 수 있습니다.

> PATH에 없다는 경고가 뜨면 아래를 `~/.zshrc`에 추가하세요.
> ```bash
> export PATH="$HOME/Library/Python/3.9/bin:$PATH"
> ```

---

## 사전 준비

### accesskey.txt

모든 커맨드가 공통으로 읽는 자격증명 파일입니다.
스크립트와 같은 디렉터리에 위치해야 하며, 탭으로 구분된 루트 계정의 액세스 키를 한 줄에 하나씩 작성합니다.

```
AKIA**********AMPLE	wJalr***************************AMPLEKEY
AKIA**********AMPLE	je7Mt***************************AMPLEKEY
```

> `#`으로 시작하는 줄은 주석으로 무시됩니다.

### TerraformWorkshop-Restricted-us-east-1.json

`awsw setup` 실행 시 필요한 IAM 정책 파일입니다. 같은 디렉터리에 있어야 합니다.

---

## 커맨드 목록

| 커맨드 | 설명 |
|--------|------|
| `awsw setup` | 수강생 IAM 유저(`terraform-user-1`) 생성 + 정책 연결 + CSV 출력 |
| `awsw teardown` | 수강생 IAM 유저 완전 삭제 + 크레덴셜 CSV 제거 |
| `awsw audit` | 잔여 리소스 스캔 (읽기 전용, 27개 서비스) |
| `awsw clean` | 잔여 리소스 스캔 후 삭제 |
| `awsw cost` | 전일(또는 지정일) 비용 리포트 |
| `awsw check` | CloudFront / ALB 서비스 한도 점검 |
| `awsw tag` | Cost Allocation 태그 활성화 |
| `awsw admin` | `terraform-user-0` AdministratorAccess 권한 보장 |
| `awsw pre` | 수업 전 준비 일괄 실행 (tag → admin → check) |
| `awsw post` | 수업 후 정리 일괄 실행 (audit → clean → teardown) |

각 커맨드의 옵션은 `awsw <command> --help`로 확인합니다.

---

## 수업 운영 흐름

```bash
# ── D-1 (수업 전날) ────────────────────────────────────────
awsw tag       # Cost 태그 활성화 (반영까지 최대 24시간 소요)
awsw admin     # terraform-user-0 어드민 권한 확인
awsw check     # CloudFront / ALB 한도 점검
# 위 셋을 한 번에: awsw pre

# ── D-Day (수업 당일) ──────────────────────────────────────
awsw setup     # 수강생 계정 생성 → workshop-credentials-*.csv 출력

# ── 수업 중 ───────────────────────────────────────────────
awsw cost      # 비용 발생 여부 확인
awsw audit     # 잔여 리소스 확인

# ── 수업 종료 후 ───────────────────────────────────────────
awsw clean     # 잔여 리소스 정리
awsw teardown  # 수강생 계정 삭제
# 위 둘을 한 번에: awsw post
```

---

## 공통 플래그

| 플래그 | 단축 | 설명 |
|--------|------|------|
| `--credentials-file PATH` | | accesskey.txt 경로 (기본값: `./accesskey.txt`) |
| `--filter RANGE` | `-f` | 특정 계정만 처리 (예: `1-5`, `1,3,5`) |
| `--output [table\|json\|csv]` | `-o` | 출력 포맷 (기본값: `table`) |
| `--dry-run` | | 실제 변경 없이 결과 미리 보기 |
| `--yes` | `-y` | 삭제 작업의 확인 프롬프트 생략 |
| `--date YYYY-MM-DD` | | `awsw cost`에서 조회 날짜 지정 (기본값: 전일) |

---

## 커맨드 상세

### `awsw setup` — 수강생 계정 설정

수강생이 워크샵에서 사용할 IAM 사용자(`terraform-user-1`)를 생성하고 권한을 부여합니다.

**동작 순서:**
1. `TerraformWorkshop-Restricted-us-east-1.json`으로 IAM 정책 생성 또는 업데이트
2. `terraform-user-1` 생성 (이미 있으면 스킵)
3. 정책 연결
4. 콘솔 로그인 프로필 생성 + 임시 패스워드 발급 (첫 로그인 시 변경 강제)
5. `workshop-credentials-YYYYMMDD-HHMMSS.csv` 저장

```bash
awsw setup
awsw setup -f 1-5          # 1~5번 계정만
```

---

### `awsw teardown` — 수강생 계정 삭제

`terraform-user-1` 및 연결된 모든 자격증명을 완전히 삭제하고, 크레덴셜 CSV 파일도 제거합니다.

```bash
awsw teardown
awsw teardown -y           # 확인 프롬프트 생략
```

---

### `awsw audit` / `awsw clean` — 잔여 리소스 감사

수업 후 삭제되지 않은 리소스를 27개 서비스에 걸쳐 전 리전 스캔합니다.
비용이 발생할 수 있는 리소스는 `[비용주의]`로 표시됩니다.

**감사 대상:**

| 구분 | 서비스 |
|------|--------|
| 글로벌 | IAM Users, CloudFront, WAFv2 (Global), Route53 |
| 리전별 | EC2, VPC, AMI, EBS, EIP, ASG, KMS, ELB v1/v2, EKS, Lambda, Secrets Manager, RDS, ECS, ECR, CodeBuild, WAFv2 (Regional) |

```bash
awsw audit                 # 읽기 전용 스캔
awsw clean                 # 스캔 후 삭제
awsw clean --dry-run       # 삭제 없이 결과 미리 보기
awsw clean -y              # 확인 프롬프트 생략
```

> CloudFront는 활성화된 배포를 즉시 삭제할 수 없습니다.
> `awsw clean` 실행 시 비활성화 요청만 하며, Deployed 상태가 된 후 재실행하면 삭제됩니다.

---

### `awsw cost` — 비용 리포트

각 계정의 전일 비용을 서비스별로 조회합니다.

```bash
awsw cost
awsw cost --date 2026-04-01   # 특정 날짜 조회
awsw cost -o csv              # CSV 형식 출력
```

> Cost Explorer 데이터는 최대 24시간 지연될 수 있습니다.

---

### `awsw check` — 서비스 한도 점검

신규 계정에서 CloudFront / ALB 생성이 차단되는 경우를 사전에 검출합니다.
실제 리소스 생성을 시도하고 즉시 삭제하므로 비용이 발생하지 않습니다.

```bash
awsw check
```

제한 계정이 발견되면 AWS Support에 해제 요청이 필요합니다.

---

### `awsw tag` — 비용 태그 활성화

Cost Explorer에서 태그 기반 비용 분석이 가능하도록 태그를 활성화합니다.
**수업 전날 실행 권장** (활성화 후 최대 24시간 후 반영).

활성화 대상: `Project`, `CostCenter`, `Environment`, `Owner`, `Name`

```bash
awsw tag
```

---

### `awsw admin` — 강사용 관리자 계정 정비

`terraform-user-0`에 `AdministratorAccess` 정책만 단독으로 연결되도록 정비합니다.

```bash
awsw admin
```

---

## 레거시 스크립트

`awsw` CLI 도입 이전의 독립 Python 스크립트들은 하위 호환을 위해 유지됩니다.
각 스크립트는 `awsw` 커맨드와 동일한 기능을 수행합니다.

| 스크립트 | 대응 커맨드 |
|----------|------------|
| `aws-workshop-setup.py` | `awsw setup` |
| `aws-workshop-teardown.py` | `awsw teardown` |
| `aws-resource-audit.py` | `awsw audit` / `awsw clean` |
| `aws-daily-cost-report.py` | `awsw cost` |
| `aws-limit-check.py` | `awsw check` |
| `aws-activate-cost-tags.py` | `awsw tag` |
| `aws-user-admin-setup.py` | `awsw admin` |
