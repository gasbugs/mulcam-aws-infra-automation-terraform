# Terraform Infrastructure Visualizer

Terraform 레포지터리의 모든 프로젝트를 **AWS 공식 아키텍처 다이어그램 스타일**로 시각화하는 웹 도구입니다.

```
[External Services]  →  [VPC]                    →  [CI/CD & Config]
  CloudFront              IGW                          CodePipeline
  S3 static               Public Subnet (ALB, NAT)     CodeBuild
  Route53                 Private/Compute (EKS, EC2)   CodeCommit
                          Database (RDS, DynamoDB)      CloudWatch
```

---

## 동작 원리

### 1단계 — HCL 파싱 (`parser/hcl_parser.py`)

`.tf` 파일을 `python-hcl2` 라이브러리로 읽어 다음 블록을 추출합니다.

```
resource "aws_lb" "wordpress" { ... }   →  리소스 목록
module "vpc" { source = "./modules/vpc" }  →  모듈 참조
data "aws_ami" "wordpress" { ... }     →  데이터 소스
variable "enable_rds" { default = true }  →  변수 정의
locals { create_db = var.enable_rds ? 1 : 0 }  →  로컬 계산값
```

### 2단계 — 모듈 확장 (`parser/module_resolver.py`)

모듈 내부에 숨어 있는 리소스를 꺼냅니다.

**로컬 모듈** (`./modules/vpc`):
- 해당 디렉터리의 `.tf` 파일을 직접 읽어 리소스 인라인 확장
- 예: `module.vpc.aws_subnet.public`

**레지스트리 모듈** (`terraform-aws-modules/vpc/aws`):
- 프로젝트 디렉터리에서 `terraform init -backend=false` 자동 실행
- `.terraform/modules/modules.json` 에서 다운로드 경로 확인
- 실제 모듈 소스(`.terraform/modules/vpc/`)를 직접 파싱

**비활성 리소스 필터링**:
- `locals` 식을 5-pass 반복 평가 (의존성 해결)
- `count = var.enable_rds ? 1 : 0` 같은 조건식을 정적 평가
- `count = 0`인 리소스는 제외

### 3단계 — 리소스 분류 (`parser/resource_catalog.py`)

95개 이상의 AWS 리소스 타입을 다음 속성으로 분류합니다.

| 속성 | 설명 | 예시 |
|------|------|------|
| `category` | 서비스 분류 | networking, compute, database, cicd ... |
| `zone` | 다이어그램 배치 영역 | public, private, external, side ... |
| `icon` | 아이콘 키 | eks, alb, rds, cloudfront ... |
| `hidden` | 기본 숨김 여부 | route_table, security_group, iam_role ... |
| `structural` | 컨테이너 여부 | aws_vpc, aws_subnet |

**Hidden 리소스** (배관 리소스): 다이어그램에는 기본적으로 표시하지 않지만, 엣지 계산에는 포함. "상세 보기" 버튼으로 표시 가능.

```
항상 표시:  aws_eks_cluster, aws_lb, aws_rds_instance, aws_s3_bucket ...
기본 숨김:  aws_security_group, aws_iam_role, aws_route_table,
           aws_eks_addon, aws_lb_listener, aws_launch_template ...
```

### 4단계 — 연결선 분석 (`parser/reference_resolver.py`)

리소스 속성값을 정규식으로 스캔해 참조 관계를 엣지로 변환합니다.

```hcl
resource "aws_lb_target_group" "wordpress" {
  vpc_id = aws_vpc.main.id          →  network 엣지 (파란색)
}
resource "aws_ecs_task_definition" "app" {
  execution_role_arn = aws_iam_role.ecs.arn  →  iam 엣지 (빨간색)
}
```

엣지 타입별 색상:
- **파란색** (network): `vpc_id`, `subnet_ids`
- **빨간색** (iam): `role_arn`, `execution_role_arn`
- **보라색** (loadbalancer): `load_balancer_arn`
- **회색** (reference): 기타 참조

### 5단계 — 레이아웃 계산 (`static/js/layout.js`)

리소스를 영역(zone)별로 배치합니다.

```
분류 규칙:
  aws_internet_gateway              → boundary (VPC 경계)
  aws_cloudfront_distribution, S3  → external (좌측 패널)
  aws_lb, aws_nat_gateway          → public (퍼블릭 서브넷)
  aws_eks_cluster, aws_instance    → private (프라이빗 서브넷)
  aws_rds_instance, aws_dynamodb   → database (데이터베이스)
  aws_codepipeline, aws_cloudwatch → side (우측 CI/CD 패널)
```

**배치 알고리즘 (bottom-up)**:
1. 각 zone의 노드 개수 → 그리드 크기 계산
2. zone별 컨테이너 높이 결정
3. VPC 높이 = 모든 zone 높이의 합 + 여백
4. 캔버스 = [External 좌] + [VPC 중] + [CI/CD 우]

### 6단계 — SVG 렌더링 (`static/js/diagram.js`)

D3.js로 SVG를 그립니다.

```
렌더링 순서 (뒤 → 앞):
1. 컨테이너 박스 (VPC → 서브넷 zones → 외부 패널)
2. 모듈 그룹 박스 (같은 모듈 리소스를 컬러 점선으로 묶음)
3. 엣지 (타입별 색상 화살표)
4. 리소스 노드 (아이콘 + 타입 + 이름)
```

---

## 아키텍처

```
terraform-visualizer/
├── server.py               # Flask API 서버
├── parser/
│   ├── project_scanner.py  # 레포 내 Terraform 프로젝트 탐색
│   ├── hcl_parser.py       # .tf 파일 파싱 (python-hcl2)
│   ├── module_resolver.py  # 로컬/레지스트리 모듈 확장
│   ├── reference_resolver.py  # 리소스 간 참조 → 엣지
│   └── resource_catalog.py    # 리소스 타입 메타데이터 DB
└── static/
    ├── index.html
    ├── css/style.css
    └── js/
        ├── app.js       # 사이드바, 프로젝트 선택, API 호출
        ├── layout.js    # 노드/컨테이너 위치 계산 알고리즘
        ├── diagram.js   # D3.js SVG 렌더링
        └── icons.js     # AWS 서비스별 인라인 SVG 아이콘
```

### API

| 엔드포인트 | 설명 |
|-----------|------|
| `GET /api/projects` | 레포 내 모든 Terraform 프로젝트 목록 |
| `GET /api/project?path=<경로>` | 특정 프로젝트 파싱 결과 |

`/api/project` 응답 구조:
```json
{
  "resources": [
    {
      "id": "aws_lb.wordpress",
      "type": "aws_lb",
      "name": "wordpress",
      "category": "loadbalancing",
      "zone": "public",
      "icon": "alb",
      "hidden": false,
      "structural": false,
      "from_module": "module.vpc"
    }
  ],
  "registry_modules": [...],
  "data_sources": [...],
  "edges": [
    { "from": "aws_lb.wordpress", "to": "aws_vpc.main", "type": "network" }
  ],
  "stats": { "total_resources": 37, "total_edges": 15 }
}
```

---

## 실행 방법

### 컨테이너 실행 (권장)

```bash
cd terraform-visualizer

# 빌드 + 실행 (podman 우선, 없으면 docker)
./run.sh

# 레포 경로 직접 지정
./run.sh --repo /path/to/terraform-repo

# 재시작 (빌드 생략)
./run.sh --no-build

# 로그 확인 / 중지
./run.sh --logs
./run.sh --stop
```

브라우저에서 `http://localhost:5001` 접속

### 로컬 실행

```bash
pip install -r requirements.txt
python server.py --repo /path/to/terraform-repo --port 5001
```

---

## 화면 기능

| 기능 | 설명 |
|------|------|
| 사이드바 프로젝트 선택 | 클릭 시 즉시 다이어그램 렌더링 |
| 노드 클릭 | 연결된 리소스/엣지 하이라이트 |
| 마우스 오버 | 리소스 상세 정보 툴팁 |
| 상세 보기 (+N) | 기본 숨김 리소스(배관) 점선으로 표시 |
| Fit 버튼 | 전체 다이어그램 화면에 맞춤 |
| Export SVG | SVG 파일로 다운로드 |
| 검색 | 프로젝트 이름 필터 |

---

## 한계 및 주의사항

- **정적 분석**: 실제 Terraform plan/apply 없이 HCL 소스만 분석합니다. 동적으로 결정되는 값(외부 데이터 소스 결과 등)은 평가할 수 없습니다.
- **레지스트리 모듈**: 최초 로드 시 `terraform init`이 자동 실행되므로 인터넷 연결과 시간이 필요합니다.
- **count/for_each**: 숫자 리터럴과 단순 변수 참조는 정적 평가하나, 복잡한 식은 "존재함"으로 간주합니다.
