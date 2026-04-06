# valkey-oss-snapshot-upgrade

Terraform을 사용하여 Amazon ElastiCache Valkey 클러스터의 **노드 타입 업그레이드**와 **스냅샷 기반 복원**을 실습하는 프로젝트입니다.  
`apply_immediately` 설정이 ElastiCache에서 어떻게 동작하는지 확인하고,  
자동 스냅샷을 통해 데이터를 보호하고 특정 시점으로 복원하는 흐름을 익히는 것을 목표로 합니다.

## 학습 목표

- ElastiCache Valkey 클러스터의 노드 타입을 Terraform으로 업그레이드한다
- `apply_immediately` 옵션이 ElastiCache에서 어떻게 동작하는지 이해한다
- `snapshot_window` / `snapshot_retention_limit`으로 자동 스냅샷을 구성한다
- `snapshot_name`을 사용하여 스냅샷으로부터 클러스터를 복원하는 방법을 실습한다

## 아키텍처

```
VPC (10.0.0.0/16)
├── Public Subnet  (10.0.3.0/24, 10.0.4.0/24)
└── Private Subnet (10.0.1.0/24, 10.0.2.0/24)
    └── ElastiCache Valkey Replication Group
        ├── Engine: Valkey 8
        ├── 노드 타입: cache.t3.micro → cache.t3.medium (업그레이드)
        ├── TLS 암호화 + AUTH 토큰
        └── 자동 스냅샷: 매일 01:00~02:00 (UTC), 7일 보관
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
valkey-oss-snapshot-upgrade/
├── main.tf           # VPC, Valkey 모듈 호출
├── variables.tf      # 입력 변수 선언
├── outputs.tf        # 출력값 (VPC ID, Redis 엔드포인트)
├── provider.tf       # AWS 프로바이더 및 Terraform 버전 설정
├── terraform.tfvars  # 실습 단계별 변수값 (단계마다 주석 전환)
├── modules/
│   └── redis/        # ElastiCache Replication Group, 서브넷 그룹, 보안 그룹
└── README.md         # 실습 가이드 (이 파일)
```

## 주요 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `redis_node_type` | `cache.t3.micro` | 노드 타입 (업그레이드 실습 시 변경) |
| `redis_num_cache_nodes` | `1` | 캐시 노드 수 |
| `redis_parameter_group_name` | `default.valkey8` | Valkey 8 파라미터 그룹 |
| `redis_auth_token` | — | 클러스터 인증 토큰 (필수) |

---

## 핵심 개념

### apply_immediately (ElastiCache)

| 설정 | 효과 |
|---|---|
| `true` | 노드 타입 변경 등 설정 변경을 즉시 적용 (짧은 다운타임 발생 가능) |
| `false` | 다음 유지 관리 시간(`maintenance_window`)에 적용 |

### 스냅샷(Snapshot)

| 항목 | 설정 | 설명 |
|---|---|---|
| `snapshot_window` | `"01:00-02:00"` | 자동 스냅샷 생성 시간 (UTC) |
| `snapshot_retention_limit` | `7` | 스냅샷 보관 기간 (일), `0`이면 자동 스냅샷 비활성화 |
| `snapshot_name` | 주석 처리 | 복원할 스냅샷 이름 — 활성화 시 해당 스냅샷으로 클러스터 재생성 |

> **주의:** `snapshot_name`을 변경하면 클러스터가 **삭제 후 재생성**됩니다. 데이터 손실에 주의하세요.

---

## 실습 소요 시간 (예상)

| 단계 | 작업 | 소요 시간 |
|---|---|---|
| 1단계 | 초기 배포 (`terraform apply`) | 약 11분 |
| 2단계 | 노드 타입 업그레이드 (`terraform apply`) | 약 13분 |
| 3단계 | 스냅샷 생성 후 복원 (`terraform apply`) | 약 10~15분 (미측정) |
| 4단계 | 리소스 정리 (`terraform destroy`) | 약 5분 |
| **합계** | | **약 39분 (3단계 제외)** |

---

## 1단계 — 초기 Valkey 클러스터 배포

### terraform.tfvars 초기 설정 확인

```hcl
# [1단계] 초기 배포 — t3.micro로 시작
redis_node_type = "cache.t3.micro"
# [2단계] 노드 타입 업그레이드 — 아래 줄 활성화 후 위 줄 주석 처리
# redis_node_type = "cache.t3.medium"
```

### 배포 실행

```bash
cd 06_db-service-management/valkey-oss-snapshot-upgrade
terraform init
terraform apply
```

배포 후 확인:
```bash
terraform output redis_cluster_endpoint
```

---

## 2단계 — 노드 타입 업그레이드

### terraform.tfvars 변경

`cache.t3.micro`를 주석 처리하고 `cache.t3.medium`을 활성화합니다.

```hcl
# [1단계] 초기 배포 — t3.micro로 시작
# redis_node_type = "cache.t3.micro"
# [2단계] 노드 타입 업그레이드 — 아래 줄 활성화 후 위 줄 주석 처리
redis_node_type = "cache.t3.medium"
```

### 업그레이드 실행

```bash
terraform apply
```

`apply_immediately = true`로 설정되어 있으므로 변경이 즉시 적용됩니다.  
노드 교체 중 짧은 다운타임이 발생할 수 있습니다.

> **ElastiCache 노드 타입 변경 동작**  
> ElastiCache는 노드 타입 변경 시 기존 노드를 새 노드로 **교체(replace)** 합니다.  
> `apply_immediately = false`이면 다음 `maintenance_window`(기본: `tue:06:30-tue:07:30`)에 적용됩니다.

---

## 3단계 — 스냅샷 생성 및 복원

### 자동 스냅샷 확인

`snapshot_window = "01:00-02:00"` 설정에 따라 매일 UTC 01:00~02:00 사이에 스냅샷이 자동 생성됩니다.  
생성된 스냅샷 목록을 CLI로 확인합니다.

```bash
# 스냅샷 목록 조회
aws elasticache describe-snapshots \
  --replication-group-id my-project-valkey \
  --profile my-profile \
  --query 'Snapshots[*].{Name:SnapshotName,Status:SnapshotStatus,Created:NodeSnapshots[0].SnapshotCreateTime}' \
  --output table
```

### 스냅샷으로부터 복원

`modules/redis/main.tf`에서 `snapshot_name` 주석을 해제하고 복원할 스냅샷 이름을 입력합니다.

```hcl
# snapshot_name = "my-redis-snapshot" 주석 해제 후 실제 스냅샷 이름으로 교체
snapshot_name = "<위에서 조회한 스냅샷 이름>"
```

```bash
terraform apply
```

> **주의:** `snapshot_name`을 변경하면 기존 클러스터가 **삭제 후 재생성**됩니다.  
> 복원이 완료되면 `snapshot_name`을 다시 주석 처리하여 이후 apply에서 재생성이 반복되지 않도록 합니다.

---

## 4단계 — 리소스 정리

```bash
terraform destroy
```

---

## 핵심 정리

| 항목 | 내용 |
|---|---|
| 노드 타입 업그레이드 | `redis_node_type` 변경 후 `terraform apply` → 노드 교체 방식으로 적용 |
| 즉시 적용 | `apply_immediately = true` → 즉시 교체, `false` → 유지 관리 시간에 적용 |
| 자동 스냅샷 | `snapshot_window` + `snapshot_retention_limit` 설정으로 매일 자동 생성 |
| 스냅샷 복원 | `snapshot_name` 설정 → 클러스터 재생성 (기존 데이터 교체) |
