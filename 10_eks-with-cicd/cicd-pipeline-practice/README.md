# EKS + CI/CD 파이프라인 실습 (직접 구성 버전)

## 실습 목표

이 실습을 통해 다음을 배울 수 있습니다:

- `cicd-pipeline` 완성 코드를 참고하면서, 직접 코드를 작성하며 CI/CD 파이프라인을 구성하는 방법
- CodePipeline, CodeBuild, ECR, EKS의 각 연결 고리를 이해하고 직접 IAM 정책을 작성하는 방법

> **참고:** 이 프로젝트는 `cicd-pipeline`의 실습 버전입니다.
> 완성된 참조 코드는 `cicd-pipeline` 디렉토리를 확인하세요.

---

## 사전 요구 사항

| 도구 | 버전 | 확인 명령어 |
|------|------|------------|
| AWS CLI | 최신 | `aws --version` |
| Terraform | >= 1.13.4 | `terraform version` |
| kubectl | 최신 | `kubectl version --client` |
| Helm | >= 3.1 | `helm version` |
| GitHub 계정 | - | CodeStar Connection 승인 필요 |

---

## 아키텍처 개요

```
GitHub 레포지토리
  │ 코드 Push
  ▼
CodePipeline
  ├── Source (GitHub)
  ├── Build  (CodeBuild → ECR Push)
  └── Deploy (ArgoCD → EKS 배포)

[지원 인프라]
  ├── S3 버킷        ── 아티팩트 저장
  ├── ECR            ── 이미지 저장소
  └── EKS 클러스터   ── 배포 대상
```

---

## 주요 리소스

`cicd-pipeline`과 동일한 리소스를 구성합니다:

| 리소스 | 설명 |
|--------|------|
| S3 버킷 | 파이프라인 아티팩트 저장 |
| ECR 레지스트리 | 컨테이너 이미지 저장소 |
| CodeBuild 프로젝트 | 빌드 실행 |
| CodePipeline | CI/CD 오케스트레이션 |
| CodeStar Connection | GitHub 연동 |
| EKS 클러스터 (v1.34) | 배포 대상 |
| ArgoCD (Helm) | GitOps 배포 |

---

## 실습 순서

### 1단계: 초기화

```bash
cd 10_eks-with-cicd/cicd-pipeline-practice
terraform init
```

### 2단계: 배포

```bash
terraform apply
```

### 3단계: GitHub 연결 승인

AWS 콘솔 → Developer Tools → Connections에서 생성된 연결을 승인합니다.

### 4단계: kubeconfig 설정

```bash
aws eks update-kubeconfig \
  --name $(terraform output -raw cluster_name) \
  --region us-east-1 \
  --profile my-profile
```

### 5단계: ArgoCD 접속 및 파이프라인 테스트

```bash
# ArgoCD 서비스 확인
kubectl get svc -n argocd

# ArgoCD 초기 비밀번호
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### 6단계: 리소스 삭제

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

## 비용 안내

> **주의:** 이 실습을 실행하면 AWS 비용이 발생합니다.

실습 종료 후 반드시 `terraform destroy`를 실행하세요.
