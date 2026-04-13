# Terraform을 활용한 WordPress on EC2 실전 구성 실습

지금까지 배운 Terraform을 활용하여 AWS 인프라를 직접 구축해보는 종합 연습 문제입니다.  
이 프로젝트에서는 VPC, RDS, EFS, Packer, ASG, ALB를 연동하여 실제 WordPress 인프라를 구축합니다.

---

## 아키텍처 구조

```
인터넷
  │
  ▼
ALB (퍼블릭 서브넷)
  │ HTTP 80
  ▼
ASG EC2 인스턴스 (프라이빗 서브넷)
  ├── EFS 마운트 (/var/www/html)
  └── RDS MySQL 연결
```

---

## 요구사항

### 1. VPC 및 서브넷 구성

3개의 서브넷 그룹을 가지는 VPC를 생성하고, 인터넷 게이트웨이 및 라우트 테이블을 구성합니다.

| 서브넷 그룹 | 용도 | CIDR |
|---|---|---|
| 퍼블릭 서브넷 | ALB(로드밸런서) 배치 | 10.0.1.0/24, 10.0.2.0/24 |
| 프라이빗 서브넷 | ASG(EC2) 배치 | 10.0.3.0/24, 10.0.4.0/24 |
| 데이터베이스 서브넷 | RDS, EFS 배치 | 10.0.5.0/24, 10.0.6.0/24 |

### 2. 보안 그룹 설정

각 구성 요소에 맞는 보안 그룹을 생성하고 최소 권한 원칙을 적용합니다.

| 보안 그룹 | 인바운드 허용 규칙 |
|---|---|
| ALB 보안 그룹 | 인터넷 전체(0.0.0.0/0)에서 HTTP(80) |
| EC2 보안 그룹 | VPC 내부(10.0.0.0/16)에서 HTTP(80) |
| RDS 보안 그룹 | VPC 내부(10.0.0.0/16)에서 MySQL(3306) |
| EFS 보안 그룹 | VPC 내부(10.0.0.0/16)에서 NFS(2049) |

### 3. RDS MySQL 데이터베이스 생성

| 항목 | 설정값 |
|---|---|
| DB 엔진 | MySQL 8.0 |
| 인스턴스 유형 | db.t3.micro |
| 스토리지 | 20GB (gp3) |
| 멀티 AZ | 활성화 |
| 배치 위치 | 데이터베이스 서브넷 그룹 |

### 4. EFS 파일시스템 생성

- `/var/www/html` (WordPress 파일) 저장용 공유 파일 스토리지
- 데이터베이스 서브넷에 마운트 타겟 생성 (각 AZ당 1개)
- EFS 보안 그룹을 통해 NFS(2049) 접근 제어

### 5. Packer AMI 빌드

RDS와 EFS가 완전히 준비된 후 Packer를 실행하여 WordPress가 설치된 AMI를 빌드합니다.

- OS: Amazon Linux 2023
- 설치 패키지: Apache httpd, PHP, php-mysqlnd
- WordPress 초기화: wp-cli를 통해 DB 연결 및 기본 설치 완료

### 6. Auto Scaling Group (ASG) 구성

| 항목 | 설정값 |
|---|---|
| Launch Template 인스턴스 유형 | t3.micro |
| AMI | Packer가 빌드한 WordPress AMI (자동 조회) |
| 최소 인스턴스 수 | 2개 |
| 최대 인스턴스 수 | 3개 |
| 배치 위치 | 프라이빗 서브넷 |
| User Data | EFS 마운트 스크립트 |

### 7. Application Load Balancer (ALB)

- 퍼블릭 서브넷에 배치
- HTTP(80) 리스너 → ASG 대상 그룹으로 포워딩
- 헬스 체크: `/` 경로로 EC2 상태 주기적 확인

---

## 파일 구조

```
wordpress-on-ec2/
├── provider.tf          # Terraform 및 AWS 프로바이더 설정
├── variables.tf         # 입력 변수 정의 (리전, DB 계정/비밀번호)
├── terraform.tfvars     # 변수 값 설정 파일
├── main.tf              # VPC, RDS, EFS, Packer 빌드
├── infra.tf             # Launch Template, ASG, ALB, 보안 그룹
├── outputs.tf           # 출력 값 (ALB DNS 주소)
└── al2023-wp-ami.pkr.hcl # Packer WordPress AMI 빌드 스크립트
```

---

## 배포 방법

```bash
# 1. 작업 디렉터리로 이동
cd wordpress-on-ec2

# 2. 초기화 (프로바이더 및 모듈 다운로드)
terraform init

# 3. 배포 계획 확인
terraform plan

# 4. 인프라 배포 (Packer 빌드 포함 - 약 15~20분 소요)
terraform apply -auto-approve

# 5. WordPress 접속 주소 확인
terraform output lb_dns
```

> **참고**: Packer가 AMI를 빌드하는 동안 `null_resource.packer_build`가 실행됩니다.  
> 완료되면 자동으로 Launch Template과 ASG가 생성됩니다.

---

## 리소스 정리

```bash
terraform destroy -auto-approve
```

---

## 풀이 요약

### 핵심 구현 포인트

1. **VPC 모듈 사용**: `terraform-aws-modules/vpc/aws` 모듈로 3계층 네트워크 구성
2. **Packer 빌드 자동화**: `terraform_data` 리소스로 RDS/EFS 준비 후 자동 빌드
3. **동적 AMI 조회**: `data "aws_ami"` 데이터 소스로 하드코딩 없이 최신 AMI 참조
4. **gp3 스토리지**: gp2 대비 성능 향상 및 비용 절감
5. **민감 정보 보호**: `sensitive = true`로 비밀번호 출력 차단

### 주요 Terraform 리소스 대응

| AWS 서비스 | Terraform 리소스 |
|---|---|
| VPC, 서브넷, IGW | `module "vpc"` |
| RDS MySQL | `aws_db_instance` |
| EFS | `aws_efs_file_system`, `aws_efs_mount_target` |
| Packer 빌드 | `terraform_data.packer_build` |
| AMI 조회 | `data "aws_ami"` |
| Launch Template | `aws_launch_template` |
| Auto Scaling Group | `aws_autoscaling_group` |
| Application Load Balancer | `aws_lb`, `aws_lb_listener`, `aws_lb_target_group` |
