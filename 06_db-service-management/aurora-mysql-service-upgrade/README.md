# aurora-mysql-service-upgrade

Terraform을 사용하여 Amazon Aurora MySQL 클러스터의 **엔진 버전**과 **인스턴스 타입**을 업그레이드하는 방법을 실습하는 프로젝트입니다.  
`apply_immediately` 설정이 클러스터와 인스턴스 각각에 어떻게 독립적으로 동작하는지 직접 확인하고,  
운영 환경에서 무중단 또는 최소 다운타임 업그레이드 전략을 이해하는 것을 목표로 합니다.

## 학습 목표

- Aurora MySQL 클러스터의 엔진 버전 업그레이드를 Terraform으로 수행한다
- `apply_immediately` 옵션의 클러스터/인스턴스 독립 적용 방식을 이해한다
- 유지 관리 시간(Maintenance Window) 기반 업데이트와 즉시 업데이트의 차이를 파악한다

## 아키텍처

```
VPC (10.0.0.0/16)
├── Public Subnet (10.0.1.0/24, 10.0.2.0/24)
│   └── EC2 (db_client) — Aurora 접속 테스트용 클라이언트
└── Private Subnet (10.0.3.0/24, 10.0.4.0/24)
    └── Aurora MySQL Cluster
        └── Instance (db.t3.medium → db.r8g.large 업그레이드)
```

## 사전 요구사항

| 항목 | 버전 |
|---|---|
| Terraform | >= 1.13.4 |
| AWS Provider | ~> 6.0 |
| AWS CLI 프로파일 | `my-profile` (`~/.aws/config` 설정 필요) |
| AWS 리전 | `us-east-1` |

## 프로젝트 구조

```
aurora-mysql-service-upgrade/
├── main.tf           # Aurora 클러스터, EC2, VPC, 보안 그룹 리소스 정의
├── variables.tf      # 입력 변수 선언
├── outputs.tf        # 출력값 (엔드포인트, 인스턴스 ID 등)
├── provider.tf       # AWS 프로바이더 및 Terraform 버전 설정
├── terraform.tfvars  # 실습 단계별 변수값 (단계마다 주석 전환)
├── modules/
│   ├── vpc/          # VPC, 서브넷, 라우팅 테이블 모듈
│   └── ec2/          # EC2 인스턴스, 키 페어, 보안 그룹 모듈
└── README.md         # 실습 가이드 (이 파일)
```

## 주요 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `db_engine_version` | `null` (자동 조회) | Aurora MySQL 엔진 버전 |
| `db_instance_class` | `db.r8g.large` | Aurora 인스턴스 클래스 |
| `aurora_instance_count` | `1` | 클러스터 인스턴스 수 |
| `backup_retention_days` | `7` | 자동 백업 보존 기간 (일) |
| `allowed_cidr` | `10.0.0.0/16` | DB 접근 허용 CIDR |

---

## 실습 소요 시간

| 단계 | 작업 | 소요 시간 |
|---|---|---|
| 1단계 | 초기 배포 (`terraform apply`) | 약 6분 |
| 2단계 | 업그레이드 (`terraform apply`) | 약 11분 |
| 3단계 | 설정 변경 후 재적용 (`terraform apply`) | 약 5분 |
| 4단계 | 리소스 정리 (`terraform destroy`) | 약 12분 |
| **합계** | | **약 34분** |

---

## 1단계 — 초기 Aurora 배포

### main.tf 확인 — apply_immediately = false

업그레이드 실습을 위해 `main.tf`에서 클러스터와 인스턴스 모두 즉시 적용이 **비활성화**되어 있는지 확인합니다.

```hcl
resource "aws_rds_cluster" "my_aurora_cluster" {
  cluster_identifier           = var.cluster_identifier
  engine                       = "aurora-mysql"
  engine_version               = local.db_engine_version
  master_username              = var.db_username
  master_password              = var.db_password
  db_subnet_group_name         = aws_db_subnet_group.this.name
  vpc_security_group_ids       = [aws_security_group.rds_sg.id]
  skip_final_snapshot          = true
  backup_retention_period      = var.backup_retention_days
  preferred_backup_window      = "07:00-09:00"
  apply_immediately            = false                          # 업데이트 즉시 적용 비활성화
  preferred_maintenance_window = "mon:05:00-mon:07:00"

  tags = {
    Name        = var.cluster_identifier
    Environment = var.environment
  }
}

resource "aws_rds_cluster_instance" "my_aurora_instance" {
  count               = var.aurora_instance_count
  identifier          = "${var.cluster_identifier}-instance-${count.index + 1}"
  cluster_identifier  = aws_rds_cluster.my_aurora_cluster.id
  instance_class      = var.db_instance_class
  engine              = "aurora-mysql"
  engine_version      = local.db_engine_version
  publicly_accessible = false
  apply_immediately   = false                                   # 업데이트 즉시 적용 비활성화

  tags = {
    Name        = "${var.cluster_identifier}-instance-${count.index + 1}"
    Environment = var.environment
  }
}
```

### terraform.tfvars 초기 설정

```hcl
# Aurora 엔진 버전 — 초기 배포 버전
db_engine_version = "8.0.mysql_aurora.3.11.1"

# Aurora 인스턴스 클래스 — Aurora MySQL 3.x(8.0) 지원 최솟값
# ※ db.t3.micro는 Aurora MySQL 3.x에서 지원되지 않음. 최솟값은 db.t3.medium
db_instance_class = "db.t3.medium"
```

### 배포 실행

```bash
cd 06_db-service-management/aurora-mysql-service-upgrade
terraform init
terraform apply
```

> **소요 시간:** 클러스터 생성 ~34초 + 인스턴스 생성 ~5분 → **총 약 6분**

---

## 2단계 — 인스턴스만 즉시 업데이트

### 개념

`apply_immediately` 설정은 클러스터와 인스턴스에 **각각 독립적으로** 적용됩니다.  
인스턴스에만 `apply_immediately = true`를 설정하면 인스턴스 타입 변경은 즉시 반영됩니다.

> **Aurora 엔진 버전 업그레이드의 특성**  
> Aurora는 클러스터와 인스턴스의 엔진 버전이 항상 동일해야 합니다.  
> 따라서 엔진 버전을 변경하면 클러스터의 `apply_immediately` 설정과 무관하게  
> **클러스터와 인스턴스가 함께 업그레이드됩니다.**  
> `apply_immediately`의 독립적 효과는 인스턴스 **클래스(타입) 변경** 같은  
> 클러스터와 무관한 변경에서 확인할 수 있습니다.

### terraform.tfvars 변경

인스턴스 타입과 엔진 버전을 업그레이드 대상으로 수정합니다.

```hcl
# Aurora 엔진 버전 — 업그레이드 목표 버전으로 변경
#db_engine_version = "8.0.mysql_aurora.3.11.1"
db_engine_version = "8.0.mysql_aurora.3.12.0"

# Aurora 인스턴스 클래스 — 현 세대 r8g로 업그레이드
db_instance_class = "db.r8g.large"
```

### main.tf 변경 — 인스턴스만 즉시 적용 활성화

```hcl
resource "aws_rds_cluster" "my_aurora_cluster" {
  # ... (생략)
  apply_immediately = false   # 클러스터 설정 변경은 유지 관리 시간 대기
  # ...
}

resource "aws_rds_cluster_instance" "my_aurora_instance" {
  # ... (생략)
  apply_immediately = true    # 인스턴스 타입 변경은 즉시 적용
  # ...
}
```

### 업데이트 실행

```bash
terraform apply
```

**결과:**
- 인스턴스 타입(`db.t3.medium` → `db.r8g.large`) 즉시 업데이트
- 엔진 버전(`3.11.1` → `3.12.0`)은 Aurora 특성상 **클러스터·인스턴스 동시** 업그레이드

> **소요 시간:** 클러스터 수정 ~3분 17초 + 인스턴스 수정 ~7분 18초 → **총 약 11분**

---

## 3단계 — 클러스터도 즉시 업데이트 (엔진 버전 분리 변경 시)

### 개념

엔진 버전은 변경하지 않고 **클러스터 수준의 설정**(예: 백업 보존 기간, 파라미터 그룹 등)만  
변경할 경우, 클러스터의 `apply_immediately` 설정이 의미를 가집니다.  
클러스터 설정 변경도 즉시 반영하려면 `aws_rds_cluster`의 `apply_immediately`를 `true`로 설정합니다.

### main.tf 변경 — 클러스터도 즉시 적용 활성화

```hcl
resource "aws_rds_cluster" "my_aurora_cluster" {
  # ... (생략)
  apply_immediately = true    # 클러스터 설정 변경도 즉시 적용
  # ...
}

resource "aws_rds_cluster_instance" "my_aurora_instance" {
  # ... (생략)
  apply_immediately = true    # 인스턴스도 즉시 적용
  # ...
}
```

### 업데이트 실행

```bash
terraform apply
```

> **소요 시간:** 약 5분

---

## 4단계 — 리소스 정리

실습이 완료되면 비용 발생을 막기 위해 반드시 리소스를 삭제합니다.

```bash
terraform destroy
```

> **소요 시간:** 인스턴스 삭제 ~9분 + 나머지 리소스 → **총 약 12분**

---

## 핵심 정리

| 설정 위치 | apply_immediately | 효과 |
|---|---|---|
| `aws_rds_cluster` | `false` | 클러스터 설정 변경 → 다음 유지 관리 시간에 적용 |
| `aws_rds_cluster` | `true` | 클러스터 설정 변경 → 즉시 적용 (짧은 다운타임 가능) |
| `aws_rds_cluster_instance` | `false` | 인스턴스 타입 변경 → 다음 유지 관리 시간에 적용 |
| `aws_rds_cluster_instance` | `true` | 인스턴스 타입 변경 → 즉시 적용 |

> **Aurora 엔진 버전 업그레이드 주의사항**  
> - Aurora MySQL은 클러스터와 인스턴스의 엔진 버전이 항상 동일해야 하므로  
>   엔진 버전 변경 시 `apply_immediately` 설정과 무관하게 클러스터·인스턴스가 **동시에** 업그레이드됩니다.  
> - `db.t3.micro`는 Aurora MySQL 3.x(MySQL 8.0 호환)에서 **지원되지 않습니다.** 최솟값은 `db.t3.medium`입니다.  
> - 유효한 엔진 버전 목록 확인 명령어:  
>   ```bash
>   aws rds describe-db-engine-versions --engine aurora-mysql \
>     --query 'DBEngineVersions[?contains(EngineVersion, `8.0.mysql_aurora.3`)].EngineVersion' \
>     --output text
>   ```
