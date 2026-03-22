# Java Spring Boot + Packer 기반 실습 프로젝트 (Docker 빌드 환경 통합)

이 프로젝트는 Spring Boot 웹 애플리케이션을 빌드한 후, AWS EC2 머신 이미지(AMI)로 패키징(Baking)하는 전체 파이프라인 실습을 위해 구성되었습니다. 
특히, 로컬(호스트) 환경에 구애받지 않고 **"뛰어난 일관성(Consistency)"**을 유지하기 위해 **Docker 컨테이너를 활용하여 오프라인 앱 빌드**를 수행한 뒤, 컴파일된 산출물(Jar)만 Packer로 EC2 이미지에 반영하는 현대적 인프라 프랙티스를 채택했습니다.

---

## 🏗️ 1. 프로젝트 파이프라인 아키텍처 (Architecture & Objective)
- **1단계 (Build in Container):** 로컬 PC에 Java나 Maven 인스톨 구성이 꼬여있어도 상관없이, Docker 컨테이너 런타임 환경 위에서 완전 격리된 컴파일을 수행하여 언제나 동일한 `.jar` 결과물을 만들어냅니다.
- **2단계 (Bake with Packer):** HashiCorp Packer를 사용하여 AWS 임시 인스턴스(가상머신)에 배포용 `.jar` 파일을 복사하고 불변 인프라(Immutable Infrastructure) 구축을 위한 골든 이미지(AMI)로 굽습니다.

### 사용된 주요 기술 스택
- **Build Container:** `maven:3.9.6-eclipse-temurin-17` (일회용 도커 빌더)
- **Framework:** Spring Boot 3.x, Java 17
- **Provisioner:** Packer, Bash 스크립트 (`setup.sh`, `build_and_pack.sh`)
- **OS Base Image:** Amazon Linux 2023 (AL2023)
- **Service Management:** Linux Systemd 

---

## 📁 2. 프로젝트 파일 구조 및 역할

| 파일명 | 역할 및 설명 |
|---|---|
| `build_and_pack.sh` | **[Main Pipeline]** 도커 기반 격리 앱 빌드(`mvn clean package`)를 유도한 뒤, 성공하면 이어서 Packer 베이킹 과정을 연속 실행하는 통합 파이프라인 쉘 스크립트 |
| `spring-app.pkr.hcl` | **[Packer Main]** 베이스 AMI를 런치하여 프로비저닝, 파일 업로드, 시스템 서비스 등록까지 관장하는 HashiCorp 빌드 템플릿 |
| `setup.sh` | [Packer Step 1] OS 패키지 업데이트 및 Java 런타임 설치 쉘 스크립트 (임시 EC2 내부에서 실행됨) |
| `spring-app.service` | [Packer Step 2] 인스턴스 부팅과 동시에 애플리케이션 서버 웹 데몬을 백그라운드로 자동 실행하기 위한 Systemd 유닛 파일 |
| `pom.xml`, `src/` | [Spring 소스] 어플리케이션 컴파일용 소스 코드 파일 세트. (일회용 도커 빌드 컨테이너 시스템 볼륨에 마운트되어 외부에서 활용됨) |

---

## 🚀 3. 실습 진행 방법 (실행 가이드)

### 요구사항
- **Docker Engine** 설치 및 백그라운드 구동 중
- **Packer** 설치
- **AWS 계정 자격 증명 연결** (AWS CLI 프로필)

디렉토리 이동 후 **통합 빌드 스크립트 파일 한 방**으로 전체 과정을 원격으로 일괄 실행합니다.

**1. 프로젝트 디렉토리 이동**
```bash
cd /Users/gasbugs/mulcam-aws-infra-automation-terraform/05_elb-asg-terraform/packer_for_javaspring
```

**2. 파이프라인 자동화 스크립트 실행**
```bash
chmod +x build_and_pack.sh
./build_and_pack.sh
```

💡 **통합 파이프라인 상세 동작 흐름:**
1. 호스트 머신의 소스 코드를 바탕으로 `maven:3.9.6` 도커 컨테이너 런타임을 임시로 띄워 애플리케이션 컴파일 (`target/demo-0...jar` 폴더에 캐시로 산출물 오프라인 복사됨)
2. Packer 시스템이 AWS 클라우드 특정 리전에 임시(Temporary) EC2 인스턴스를 즉각 런치
3. 방금 전 로컬에서 도커에 의해 컴파일된 `.jar` 릴리즈 파일과 `spring-app.service`를 EC2 안으로 안전하게 업로드 전송
4. EC2에서 `setup.sh` 구동시켜 오직 구동을 위한 런타임 환경(Amazon Corretto 17 등) 설치
5. 애플리케이션을 AWS EC2 재시동 시마다 자동으로 뜨도록 Linux Systemd에 등록 (systemctl enable)
6. 이 세팅들이 모두 끝난 임시 서버의 EBS 스냅샷을 떠내어 완성된(Bake된) AMI로 추출 후 임시 클라우드 인스턴스 삭제

---

## ⏭️ 4. 향후 확장 워크플로우 (Next Steps)
방금의 통합 파이프라인 로그 마지막 줄에서 `ami-xxx` 형태의 고유 AWS 머신 이미지 ID 획득에 성공했다면, 인프라 자동화 실습 아이디어로 이어서 진행할 수 있습니다.
- **Terraform 연동 Immutable 인프라 배포:** 상위 폴더 계층에 구성해 놓은 테라폼 파이프라인 코드(AWS Auto Scaling Group, ALB 컴포넌트 등) 내 하드코딩된 `ami_id` 파라미터를 방금 전 스냅샷이 끝난 이미지의 ID로 교체하여 수십, 수백대의 인스턴스 클러스터 프로비저닝 실습으로 연결할 수 있습니다.
