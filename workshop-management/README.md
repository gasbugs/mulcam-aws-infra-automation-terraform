# AWS 워크샵 관리 스크립트

Terraform 워크샵 운영을 위한 AWS 계정 관리 자동화 도구 모음입니다.
`accesskey.txt`에 등록된 모든 루트 계정을 대상으로 병렬로 동작합니다.

---

## 파일 기능 요약

| 파일 | 대상 계정/사용자 | 주요 기능 | 실행 결과 |
|------|----------------|----------|----------|
| `aws-activate-cost-tags.py` | 루트 계정 전체 | Cost Allocation Tags(`Project` 등 5종) 활성화 | 미등록 태그는 임시 VPC로 등록 후 활성화 |
| `aws-limit-check.py` | 루트 계정 전체 | CloudFront · ALB 생성 한도 제한 여부 점검 | 제한 계정 목록 출력 (AWS Support 문의 대상) |
| `aws-workshop-setup.py` | 루트 계정 전체 | `terraform-user-1` 생성 + 제한 정책 연결 + 콘솔 패스워드 발급 | 로그인 정보 CSV 파일 생성 |
| `aws-user-admin-setup.py` | 루트 계정 전체 | `terraform-user-0`에 `AdministratorAccess` 단독 연결 보장 | 불필요한 정책 분리 및 관리자 권한 정비 |
| `aws-daily-cost-report.py` | 루트 계정 전체 | 전일 비용을 서비스별로 조회 · 비용 발생 계정 강조 | 비용 발생 계정 목록 및 서비스별 금액 출력 |
| `aws-resource-audit.py` | 루트 계정 전체 | 27개 서비스 유형의 잔여 리소스 스캔 + IAM/CloudFront 자동 정리 | 잔여 리소스 목록 및 정리 결과 출력 |
| `aws-workshop-teardown.py` | 루트 계정 전체 | `terraform-user-1` 및 연결 자격증명 완전 삭제 + CSV 파일 제거 | 수강생 계정 원상 복구 |

---

## 사전 준비

### accesskey.txt

모든 스크립트가 공통으로 읽는 자격증명 파일입니다.
스크립트와 같은 디렉터리에 위치해야 하며, 탭으로 구분된 루트 계정의 액세스 키를 한 줄에 하나씩 작성합니다.

```
AKIA**********AMPLE	wJalr***************************AMPLEKEY
AKIA**********AMPLE	je7Mt***************************AMPLEKEY
```

> `#`으로 시작하는 줄은 주석으로 무시됩니다.

---

## 스크립트 목록 및 사용 시점

### 수업 전 준비 단계

| 순서 | 스크립트 | 실행 타이밍 |
|------|----------|------------|
| 1 | `aws-activate-cost-tags.py` | 수업 **전날** — 태그 활성화는 24시간 후 반영 |
| 2 | `aws-limit-check.py` | 수업 **당일 전** — 계정 제한 사전 점검 |
| 3 | `aws-workshop-setup.py` | 수업 **당일** — 수강생 계정 생성 및 배포 |
| 4 | `aws-user-admin-setup.py` | 필요 시 — 강사용 관리자 계정 정비 |

### 수업 중 / 수업 후

| 스크립트 | 실행 타이밍 |
|----------|------------|
| `aws-daily-cost-report.py` | 매일 — 비용 발생 여부 모니터링 |
| `aws-resource-audit.py` | 수업 후 — 잔여 리소스 확인 및 정리 |
| `aws-workshop-teardown.py` | 수업 종료 후 — 수강생 계정 완전 삭제 |

---

## 스크립트 상세 설명

### 1. `aws-activate-cost-tags.py` — 비용 태그 활성화

Cost Explorer에서 태그 기반 비용 분석을 사용하려면 태그를 미리 "활성화"해야 합니다.
활성화 후 최대 24시간이 지나야 데이터가 검색되므로 **수업 전날 반드시 실행**합니다.

**활성화 대상 태그:** `Project`, `CostCenter`, `Environment`, `Owner`, `Name`

**동작 순서:**
1. 각 계정에서 대상 태그의 현재 상태 조회 (`Active` / `Inactive` / 미등록)
2. 미등록 태그가 있으면 임시 VPC를 생성해 5개 태그를 모두 부착하고 즉시 삭제
   - VPC 자체는 비용이 발생하지 않음
   - 이 과정으로 Cost Explorer가 태그 키를 인식하게 됨
3. `Inactive` 상태인 태그를 `Active`로 활성화
4. 이미 모두 `Active`이면 추가 API 호출 없이 스킵

**실행:**
```bash
python aws-activate-cost-tags.py
```

**출력 예시:**
```
  현재 태그 상태:
    [미등록] Project
    [미등록] CostCenter
    [활성]   Environment
  [안내] 임시 VPC를 생성해 태그를 Cost Explorer에 등록합니다.
  [VPC] 임시 VPC 삭제 완료: vpc-0abc1234
  [성공] 3개 태그 활성화 완료
```

---

### 2. `aws-limit-check.py` — 서비스 한도 확인

신규 AWS 계정은 CloudFront 배포나 ALB 생성이 차단되는 경우가 있습니다.
수업 전에 미리 확인해 제한된 계정을 파악하고 AWS Support에 해제 요청할 수 있습니다.

**확인 항목:**
- **CloudFront** — 계정 미인증으로 인한 배포 생성 차단 여부
- **ALB** (us-east-1) — 로드밸런서 생성 지원 여부

**동작 방식:**
실제로 리소스 생성을 시도하고 오류 메시지로 제한 여부를 판별합니다.
생성에 성공하면 즉시 삭제하여 비용이 발생하지 않도록 합니다.

**실행:**
```bash
python aws-limit-check.py
```

**출력 예시:**
```
  결과 → CloudFront: [정상]  /  ALB: [제한]

[최종 통계 요약]
  CloudFront  정상: 9개  /  제한: 1개
  ALB         정상: 8개  /  제한: 2개

[제한 발생 계정 목록]  (AWS Support 문의 필요)
  계정 3   계정 ID: 123456789012   ALB: 제한
```

---

### 3. `aws-workshop-setup.py` — 수강생 계정 설정

수강생이 워크샵에서 사용할 IAM 사용자(`terraform-user-1`)를 생성하고 권한을 부여합니다.
생성된 로그인 정보는 CSV 파일로 저장되어 수강생에게 배포할 수 있습니다.

**동작 순서:**
1. `TerraformWorkshop-Restricted-us-east-1.json` 파일을 읽어 IAM 정책 생성 또는 업데이트
2. `terraform-user-1` IAM 사용자 생성 (이미 있으면 스킵)
3. 정책을 사용자에게 연결
4. 콘솔 로그인 프로필 생성 및 임시 패스워드 발급 (첫 로그인 시 변경 강제)
5. 계정별 로그인 URL과 초기 패스워드를 `workshop-credentials-YYYYMMDD-HHMMSS.csv`로 저장

**사전 준비:**
- `accesskey.txt`
- `TerraformWorkshop-Restricted-us-east-1.json` (정책 파일, 같은 디렉터리)

**실행:**
```bash
python aws-workshop-setup.py
```

**생성 결과:**
- IAM 사용자: `terraform-user-1`
- 로그인 URL: `https://<계정ID>.signin.aws.amazon.com/console`
- CSV 파일: `workshop-credentials-20260101-090000.csv`

> 이미 사용자가 존재하면 정책만 최신 상태로 업데이트하고 패스워드는 변경하지 않습니다.

---

### 4. `aws-user-admin-setup.py` — 강사용 관리자 계정 정비

`terraform-user-0` 사용자에게 `AdministratorAccess` 정책만 단독으로 연결되도록 정비합니다.
강사가 수강생 계정에서 실습 리소스를 자유롭게 관리할 때 사용합니다.

**동작 순서:**
1. `terraform-user-0` 사용자가 없으면 생성
2. `AdministratorAccess` 이외의 관리형 정책 전부 분리
3. 인라인 정책 전부 삭제
4. `AdministratorAccess` 미연결 시 연결

**실행:**
```bash
python aws-user-admin-setup.py
```

> `aws-daily-cost-report.py`도 이 사용자(`terraform-user-0`)를 Cost Explorer 조회용으로 사용합니다.

---

### 5. `aws-daily-cost-report.py` — 일일 비용 리포트

수업 기간 동안 각 계정에서 전일 발생한 비용을 서비스별로 조회합니다.
비용이 남아있는 계정을 파악해 리소스 삭제를 안내할 수 있습니다.

**동작 순서:**
1. `terraform-user-0` 사용자가 없으면 생성하고 Cost Explorer 읽기 권한 부여
2. 전일(`어제 00:00 ~ 24:00`) 비용을 서비스별로 조회
3. 비용이 있는 계정은 `[경고]`, 없는 계정은 `[성공]`으로 표시

**실행:**
```bash
python aws-daily-cost-report.py
```

**출력 예시:**
```
  [경고] 비용 발생 — 합계: $1.2400 USD
    ████████████████████  $0.9800 USD  Amazon EC2
    ████                  $0.2600 USD  Amazon RDS

[삭제 조치 필요 계정]
  계정 2   계정 ID: 234567890123   합계: $1.2400 USD
```

> Cost Explorer 데이터는 최대 24시간 지연될 수 있습니다.

---

### 6. `aws-resource-audit.py` — 잔여 리소스 감사

수업 후 수강생이 삭제하지 않은 AWS 리소스를 전 계정에 걸쳐 스캔합니다.
비용이 발생할 수 있는 리소스는 `[비용주의]`로 강조 표시됩니다.
또한 예약 사용자(`terraform-user-0`, `terraform-user-1`) 외의 IAM 사용자와
CloudFront 배포를 자동으로 정리합니다.

**검사 대상 (27개 서비스 유형):**

| 구분 | 서비스 |
|------|--------|
| 글로벌 | IAM Users, CloudFront, WAFv2 ACLs (Global), Route53 Hosted Zones |
| 리전별 | EC2 Instances, VPC (비기본), AMI, EBS Snapshots/Volumes, EIP, ASG, KMS, ELB v1/v2, EKS, Lambda, Secrets Manager, RDS, ECS, ECR, CodeBuild, WAFv2 (Regional) |

**자동 정리 동작:**
- **IAM 사용자** — 예약 사용자 제외 전부 삭제 (액세스 키, 정책, MFA 등 포함)
- **CloudFront** — 비활성화된 배포는 즉시 삭제 / 활성화된 배포는 비활성화 요청 후 재실행 시 삭제

**실행:**
```bash
python aws-resource-audit.py
```

**출력 예시:**
```
  [경고] 발견된 잔여 리소스 (3건):
    - EC2 Instances 리소스 2개 발견 (리전: us-east-1)
    - [비용주의] Route53 Hosted Zones 2개 발견 → 퍼블릭: example.com
    - EBS Volumes 리소스 1개 발견 (리전: us-east-1)
```

---

### 7. `aws-workshop-teardown.py` — 수강생 계정 완전 삭제

워크샵 종료 후 수강생 IAM 사용자(`terraform-user-1`)와 관련 자격증명 파일을 모두 삭제합니다.

**동작 순서:**
1. 연결된 관리형 정책 해제
2. 인라인 정책 삭제
3. 콘솔 로그인 프로필 삭제
4. 액세스 키 삭제
5. MFA 디바이스 비활성화 및 삭제
6. IAM 그룹에서 제거
7. 서명 인증서 / SSH 퍼블릭 키 / 서비스별 자격증명 삭제
8. `terraform-user-1` 사용자 최종 삭제
9. `workshop-credentials-*.csv` 파일 전체 삭제

**실행:**
```bash
python aws-workshop-teardown.py
```

> 사용자가 이미 없는 계정은 오류 없이 건너뜁니다.

---

## 권장 실행 순서 (전체 워크샵 흐름)

```
[수업 전날]
  python aws-activate-cost-tags.py   # 비용 태그 활성화 (24h 대기)

[수업 당일 전]
  python aws-limit-check.py          # CloudFront / ALB 한도 확인
  python aws-user-admin-setup.py     # 강사용 관리자 계정 정비 (필요 시)
  python aws-workshop-setup.py       # 수강생 계정 생성 → CSV 배포

[수업 중 / 매일]
  python aws-daily-cost-report.py    # 비용 모니터링

[수업 종료 후]
  python aws-resource-audit.py       # 잔여 리소스 감사 및 자동 정리
  python aws-workshop-teardown.py    # 수강생 계정 완전 삭제
```
