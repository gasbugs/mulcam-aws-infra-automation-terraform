# AWS Image Builder — Spring Boot AMI 자동 빌드 실습

## 학습 목표

`packer-for-javaspring` 프로젝트에서 Packer로 만들던 Spring Boot AMI를
**AWS Image Builder + Terraform**으로 동일하게 구현합니다.

두 도구의 역할을 비교하며 AWS 관리형 이미지 빌드 서비스의 구조를 이해합니다.

---

## Packer vs AWS Image Builder

| 항목 | Packer | AWS Image Builder |
|------|--------|-------------------|
| 실행 방식 | 로컬 CLI에서 SSH로 제어 | AWS 관리형 서비스 (SSM Agent) |
| 소스 코드 관리 | 로컬 파일 직접 참조 | CodeCommit(Git 저장소) 연동 |
| 컴포넌트 정의 | HCL + shell inline | YAML 문서 (`aws_imagebuilder_component`) |
| 스케줄 빌드 | 불가 (수동 실행) | 가능 (cron 스케줄 설정) |
| 빌드 로그 | 로컬 stdout | CloudWatch Logs / S3 자동 저장 |
| 비용 | 빌드 시간만큼 EC2 요금 | 동일 (+ S3 저장 비용) |

---

## 아키텍처

```
[개발자 PC]
  packer-for-javaspring/ (Spring Boot 소스)
      │
      │  push-to-codecommit.sh 실행
      ▼
[AWS CodeCommit: spring-boot-app]
      │
      │  Image Builder 파이프라인 실행 시 git clone
      ▼
[AWS Image Builder Pipeline]
  ┌─────────────────────────────────────────────┐
  │  Image Recipe v1.0.x                        │
  │    Base AMI: Amazon Linux 2023 (최신)        │
  │    Component 1: install-java17              │
  │      └─ Java 17, Maven, Git 설치            │
  │    Component 2: deploy-spring-app           │
  │      ├─ CodeCommit에서 소스 clone           │
  │      ├─ mvn clean package (단위 테스트 포함) │
  │      ├─ JAR → /home/ec2-user/app/ 복사      │
  │      ├─ systemd 서비스 등록                  │
  │      └─ 소스코드 · Maven 캐시 삭제          │
  ├─────────────────────────────────────────────┤
  │  Infrastructure Config                      │
  │    └─ t3.micro, IAM Instance Profile        │
  ├─────────────────────────────────────────────┤
  │  Distribution Config                        │
  │    └─ AMI 이름, 태그, 배포 리전              │
  └─────────────────────────────────────────────┘
      │
      ▼
[결과 AMI: spring-boot-app-ami-YYYYMMDDHHMMSS]
  - Java 17 설치됨
  - Spring Boot JAR (/home/ec2-user/app/) 설치됨
  - systemd 서비스 자동 시작 설정됨
  - 소스코드 없음 (보안을 위해 빌드 후 삭제)
```

---

## 파일 구조

```
image-builder/
├── README.md            ← 이 파일
├── provider.tf          ← AWS 프로바이더 · 계정 정보 조회
├── variables.tf         ← 입력 변수 (리전, 프로파일, 버전 등)
├── outputs.tf           ← 파이프라인 ARN · CodeCommit URL 출력
├── s3.tf                ← 빌드 로그 저장용 S3 버킷
├── iam.tf               ← IAM 역할 · 정책 · 인스턴스 프로파일
├── codecommit.tf        ← Spring Boot 소스 저장소
├── components.tf        ← Image Builder 컴포넌트 2개 (YAML 문서)
├── recipe.tf            ← Image Recipe (베이스 AMI + 컴포넌트 조합)
├── infrastructure.tf    ← 빌드용 EC2 환경 · CloudWatch 로그 그룹
├── distribution.tf      ← 완성 AMI 이름 · 태그 · 배포 리전
├── pipeline.tf          ← 파이프라인 (위 설정들을 하나로 연결)
└── push-to-codecommit.sh ← 소스 코드를 CodeCommit에 push하는 헬퍼 스크립트
```

---

## 실습 순서

### 사전 조건

- AWS CLI 설치 및 `my-profile` 프로파일 설정 완료
- Terraform >= 1.13.4 설치

---

### Step 1. Terraform으로 AWS 리소스 생성

```bash
cd 05_elb-asg-terraform/image-builder

terraform init
terraform plan
terraform apply
```

완료되면 다음과 같은 출력이 나타납니다:

```
codecommit_clone_url_http = "https://git-codecommit.us-east-1.amazonaws.com/v1/repos/spring-boot-app"
pipeline_arn = "arn:aws:imagebuilder:us-east-1:..."
start_pipeline_command = "aws imagebuilder start-image-pipeline-execution ..."
```

---

### Step 2. Spring Boot 소스를 CodeCommit에 push

헬퍼 스크립트를 실행합니다. 확인 프롬프트에서 `y`를 입력하면 push가 진행됩니다.

```bash
./push-to-codecommit.sh
```

> **스크립트가 하는 일**
> 1. `terraform output`에서 CodeCommit URL 자동 조회
> 2. `../packer-for-javaspring/` 디렉토리로 이동
> 3. `pom.xml`과 `src/` 디렉토리만 선택하여 git add
> 4. CodeCommit에 push

---

### Step 3. 파이프라인 실행 (AMI 빌드 시작)

```bash
aws imagebuilder start-image-pipeline-execution \
  --image-pipeline-arn $(terraform output -raw pipeline_arn) \
  --profile my-profile \
  --region us-east-1
```

---

### Step 4. 빌드 상태 확인

빌드는 보통 **10~20분** 소요됩니다.

```bash
# 빌드 ARN은 start-image-pipeline-execution 응답의 imageBuildVersionArn 값
aws imagebuilder get-image \
  --image-build-version-arn <imageBuildVersionArn> \
  --profile my-profile \
  --region us-east-1 \
  --query 'image.state'
```

상태 값:
| 상태 | 의미 |
|------|------|
| `BUILDING` | 빌드 진행 중 |
| `TESTING` | 이미지 테스트 중 |
| `DISTRIBUTING` | AMI 등록 중 |
| `AVAILABLE` | 완료 — AMI 사용 가능 |
| `FAILED` | 실패 — CloudWatch 로그 확인 필요 |

빌드 로그는 AWS 콘솔 **EC2 Image Builder → 이미지 파이프라인 → 출력 이미지** 에서도 확인할 수 있습니다.

---

### Step 5. 실습 완료 후 리소스 삭제

```bash
terraform destroy
```

> **주의:** `terraform destroy`는 Image Builder 리소스만 삭제합니다.
> 빌드로 생성된 **AMI와 EBS 스냅샷**은 자동 삭제되지 않으므로
> AWS 콘솔에서 수동으로 삭제해야 합니다.
>
> EC2 콘솔 → AMI → AMI 선택 → 등록 취소  
> EC2 콘솔 → 스냅샷 → 스냅샷 선택 → 삭제

---

## 컴포넌트 수정 시 주의사항

Image Builder는 **동일 버전의 컴포넌트 덮어쓰기를 허용하지 않습니다.**
`components.tf`를 수정할 때는 반드시 `variables.tf`의 `recipe_version`을 올려야 합니다.

```hcl
# variables.tf
variable "recipe_version" {
  default = "1.0.3"  # 수정 후 1.0.4로 올리기
}
```

버전을 올리지 않으면 `terraform apply` 시 오류가 발생합니다.

---

## 핵심 개념 정리

### Image Builder의 구성 요소 관계

```
Pipeline (파이프라인)
  ├── Recipe (레시피) ──────── "무엇을 만들지"
  │     ├── Base AMI
  │     └── Components[] ──── "어떤 작업을 할지"
  ├── Infrastructure Config ─ "어디서 만들지 (EC2 설정)"
  └── Distribution Config ─── "어디에 저장할지 (AMI 이름/리전)"
```

### Packer provisioner vs Image Builder Component 비교

| Packer (`spring-app.pkr.hcl`) | Image Builder (`components.tf`) |
|-------------------------------|----------------------------------|
| `provisioner "shell" { script = "./setup.sh" }` | Component 1: Java/Maven/Git 설치 |
| `provisioner "file" { source = "target/*.jar" }` | Component 2: clone → build → copy JAR |
| `provisioner "shell" { inline = ["systemctl enable ..."] }` | Component 2: systemd 등록 |
