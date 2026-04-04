# Java Spring Boot + Packer 기반 AMI 빌드 프로젝트

이 프로젝트는 Spring Boot 웹 애플리케이션을 빌드한 후, AWS EC2 머신 이미지(AMI)로 패키징(Baking)하는 전체 파이프라인 실습을 위해 구성되었습니다.
로컬 환경에 관계없이 **Docker/Podman 컨테이너** 안에서 앱을 빌드하고, 컴파일된 JAR 파일만 Packer로 EC2 이미지에 반영하는 불변 인프라(Immutable Infrastructure) 패턴을 채택했습니다.

---

## 1. 파이프라인 아키텍처

```
[build.sh]                          [pack.sh]
Docker/Podman 컨테이너              Packer (AWS EC2 임시 인스턴스)
  └─ mvn clean package        →       └─ setup.sh        (Java 17 설치)
       └─ target/*.jar                └─ JAR 파일 업로드
                                      └─ spring-app.service 등록
                                      └─ AMI 추출 후 인스턴스 삭제
```

- **1단계 (build.sh):** Docker 또는 Podman 컨테이너 안에서 Maven 빌드를 수행하여 `target/demo-0.0.1-SNAPSHOT.jar`를 생성합니다. 로컬에 Java/Maven이 없어도 동일한 결과물을 만들어냅니다.
- **2단계 (pack.sh):** Packer가 AWS 임시 인스턴스를 띄워 JAR 파일을 복사하고, systemd 서비스를 등록한 뒤 골든 이미지(AMI)로 굽습니다.

### 사용 기술 스택

| 구분 | 내용 |
|---|---|
| 빌드 컨테이너 | `maven:3.9.6-eclipse-temurin-17` |
| 프레임워크 | Spring Boot 3.x, Java 17 |
| AMI 빌드 | HashiCorp Packer `~> 1.3` |
| 베이스 OS | Amazon Linux 2023 (AL2023) |
| 서비스 관리 | Linux systemd |

---

## 2. 파일 구조

| 파일 | 역할 |
|---|---|
| `build.sh` | Docker/Podman으로 JAR 빌드만 수행 |
| `pack.sh` | JAR 존재 확인 후 Packer로 AMI 굽기만 수행 |
| `build_and_pack.sh` | `build.sh` → `pack.sh` 순서로 일괄 실행하는 진입점 |
| `spring-app.pkr.hcl` | Packer 빌드 템플릿 (AMI 이름, 플러그인, 프로비저닝 순서 정의) |
| `setup.sh` | Packer 프로비저닝 중 EC2 내부에서 실행되는 패키지 설치 스크립트 |
| `spring-app.service` | systemd 유닛 파일 — 인스턴스 부팅 시 앱 자동 실행 |
| `pom.xml`, `src/` | Spring Boot 애플리케이션 소스 코드 |
| `target/*.jar` | 빌드 결과물 JAR (Git 추적 대상, `.jar.original` 제외) |

---

## 3. 요구사항

- **Docker** 또는 **Podman** (컨테이너 빌드용)
- **Packer** CLI 설치
- **AWS CLI** 프로파일 설정 (`my-profile`)

---

## 4. 실행 방법

### 단계별 실행 (권장)

```bash
cd 05_elb-asg-terraform/packer-for-javaspring

# 1단계: JAR 빌드
./build.sh

# 2단계: AMI 굽기
AWS_PROFILE=my-profile ./pack.sh
```

### 한 번에 실행

```bash
cd 05_elb-asg-terraform/packer-for-javaspring
AWS_PROFILE=my-profile ./build_and_pack.sh
```

### 빌드 완료 후 흐름

```
pack.sh 실행 완료
  → 로그 마지막 줄에서 AMI ID 확인 (ami-xxxxxxxxxxxxxxxxx)
  → Terraform의 data "aws_ami"로 조회하여 EC2/ASG 배포에 활용
```

---

## 5. Packer 템플릿 주요 설정

| 항목 | 값 |
|---|---|
| 플러그인 버전 | `~> 1.3` (마이너 버전 고정) |
| 베이스 AMI | Amazon Linux 2023 최신 버전 자동 조회 |
| 인스턴스 타입 | `t3.micro` |
| AMI 이름 패턴 | `spring-boot-app-ami-{타임스탬프}` |
| AMI 태그 | `Name`, `BuildDate`, `OS`, `App` |

---

## 6. 향후 확장

빌드된 AMI ID를 상위 Terraform 프로젝트(`spring-app-ec2/`)에서 `data "aws_ami"`로 조회하여 EC2 인스턴스 또는 Auto Scaling Group 배포에 연결할 수 있습니다.
