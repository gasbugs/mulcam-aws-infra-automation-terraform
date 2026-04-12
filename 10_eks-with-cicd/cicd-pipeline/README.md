# EKS + CI/CD 파이프라인 실습 (완성 버전)

## 실습 목표

이 실습을 통해 다음을 배울 수 있습니다:

- AWS CodePipeline, CodeBuild, ECR, EKS를 연결하여 완전한 CI/CD 파이프라인을 구축하는 방법
- GitHub 코드 변경 → 자동 빌드 → 컨테이너 이미지 Push → EKS 배포까지의 전체 흐름 이해
- CodeStar Connections(GitHub 연동), S3(아티팩트 저장), CloudWatch Logs(빌드 로그) 구성 방법
- ArgoCD를 사용한 GitOps 방식의 배포 자동화

---

## 사전 요구 사항

| 도구 | 버전 | 확인 명령어 |
|------|------|------------|
| AWS CLI | 최신 | `aws --version` |
| Terraform | >= 1.13.4 | `terraform version` |
| kubectl | 최신 | `kubectl version --client` |
| Helm | >= 2.16 | `helm version` |
| GitHub 계정 | - | GitHub에서 직접 연결 승인 필요 |

---

## 아키텍처 개요

```
GitHub 레포지토리
  │ 코드 Push
  ▼
CodeStar Connection (GitHub 연동)
  │
  ▼
CodePipeline
  ├── Source Stage    ── GitHub에서 코드 가져오기
  ├── Build Stage     ── CodeBuild: Docker 이미지 빌드 → ECR Push
  └── Deploy Stage    ── ArgoCD: EKS 클러스터에 배포
        │
        ▼
ECR 레지스트리 (product-app)
        │
        ▼
EKS 클러스터 (v1.34)
  └── ArgoCD
        └── 애플리케이션 자동 배포

[지원 인프라]
  ├── S3 버킷        ── 파이프라인 아티팩트 저장
  ├── CloudWatch 로그 ── CodeBuild 빌드 로그 저장
  └── IAM 역할       ── CodePipeline, CodeBuild 실행 권한
```

---

## 주요 리소스

| 리소스 | 설명 | 특이사항 |
|--------|------|---------|
| S3 버킷 | 파이프라인 빌드 아티팩트 저장 | `force_destroy = true` |
| ECR 레지스트리 | 컨테이너 이미지 저장소 | `product-app` |
| CodeBuild 프로젝트 | Docker 이미지 빌드 및 ECR Push | CloudWatch 로그 연동 |
| CodePipeline | 전체 CI/CD 흐름 오케스트레이션 | GitHub → Build → Deploy 3단계 |
| CodeStar Connection | GitHub 레포지토리 연동 | 콘솔에서 수동 승인 필요 |
| EKS 클러스터 (v1.34) | 배포 대상 Kubernetes 클러스터 | c5.large 노드 그룹 |
| ArgoCD (Helm) | GitOps 기반 배포 자동화 | `argocd` 네임스페이스 |

---

## 실습 순서

### 1단계: 초기화

```bash
cd 10_eks-with-cicd/cicd-pipeline
terraform init
```

### 2단계: 배포 (약 25~30분 소요)

```bash
terraform apply
```

### 3단계: GitHub 연결 승인 (중요!)

CodeStar Connection은 처음 생성 시 수동 승인이 필요합니다:

1. AWS 콘솔 → Developer Tools → Connections 메뉴 이동
2. 생성된 연결(Connection)을 선택
3. "Update pending connection" 클릭
4. GitHub 계정으로 로그인 후 승인

### 4단계: kubeconfig 설정

```bash
aws eks update-kubeconfig \
  --name $(terraform output -raw cluster_name) \
  --region us-east-1 \
  --profile my-profile
```

### 5단계: ArgoCD 접속

```bash
# ArgoCD 서버 주소 확인
kubectl get svc -n argocd argocd-server

# ArgoCD 초기 비밀번호 확인
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

ArgoCD 웹 UI: `https://<ArgoCD 서비스 주소>` (ID: admin)

### 6단계: 파이프라인 동작 확인

GitHub 레포지토리에 코드를 Push하면:

1. CodePipeline이 자동으로 시작됨
2. CodeBuild에서 Docker 이미지 빌드 및 ECR Push
3. ArgoCD가 변경 사항을 감지하여 EKS에 배포

```bash
# 파이프라인 실행 상태 확인 (콘솔 또는 CLI)
aws codepipeline get-pipeline-state \
  --name <파이프라인 이름> \
  --profile my-profile
```

### 7단계: 리소스 삭제

```bash
terraform destroy
```

---

## 변수 설명

| 변수명 | 설명 | 기본값 |
|--------|------|--------|
| `aws_region` | 리소스를 배포할 AWS 리전 | `"us-east-1"` |
| `tf_user` | 리소스 이름에 포함될 사용자 식별자 | `"gasbugs"` |

---

## CI/CD 파이프라인 주요 개념

| 용어 | 설명 |
|------|------|
| CodePipeline | AWS 완전 관리형 CI/CD 오케스트레이터 |
| CodeBuild | 서버리스 빌드 서버 (Docker 빌드, 테스트 실행) |
| CodeStar Connections | GitHub, GitLab 등 외부 Git 레포지토리 연동 |
| ArgoCD | GitOps 방식의 Kubernetes 배포 도구 |
| GitOps | Git을 유일한 진실의 원천(Single Source of Truth)으로 사용하는 운영 방식 |

---

## 비용 안내

> **주의:** 이 실습을 실행하면 AWS 비용이 발생합니다.

실습 종료 후 반드시 `terraform destroy`를 실행하세요.
