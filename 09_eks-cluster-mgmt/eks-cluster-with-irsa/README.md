# EKS 클러스터 + IRSA(S3 접근) 실습

## 실습 목표

이 실습을 통해 다음을 배울 수 있습니다:

- IRSA(IAM Roles for Service Accounts)의 동작 원리를 이해
- Kubernetes 파드가 AWS S3에 접근할 수 있도록 IRSA로 IAM 권한을 안전하게 부여하는 방법
- EBS CSI와 S3 접근 두 가지 IRSA 역할을 동시에 구성하는 방법

> **핵심 개념:** IRSA를 사용하면 파드가 AWS IAM 역할의 권한을 직접 사용할 수 있어, 노드에 광범위한 권한을 부여하는 것보다 훨씬 안전합니다.

> **참고:** 이 프로젝트는 실습 진행 중(_pending)인 버전입니다.

---

## 사전 요구 사항

| 도구 | 버전 | 확인 명령어 |
|------|------|------------|
| AWS CLI | 최신 | `aws --version` |
| Terraform | >= 1.13.4 | `terraform version` |
| kubectl | 최신 | `kubectl version --client` |

---

## 아키텍처 개요

```
[EKS 클러스터 (v1.34)]
  └── 파드 (Kubernetes ServiceAccount 사용)
        └── IRSA 연동
              ├── OIDC 프로바이더 (EKS → AWS IAM 신뢰 연결)
              └── IAM 역할
                    ├── S3 접근 역할 ── s3:GetObject, s3:PutObject
                    └── EBS CSI 역할 ── EBS 볼륨 관리
```

---

## 주요 리소스

| 리소스 | 설명 | 특이사항 |
|--------|------|---------|
| EKS 클러스터 (v1.34) | Kubernetes 클러스터 (노드 그룹 2개) | 퍼블릭 엔드포인트 |
| 노드 그룹 1 (node-group-1) | t3.small, 최대 3개 | 일반 워크로드 |
| 노드 그룹 2 (node-group-2) | t3.small, 최대 2개 | 보조 그룹 |
| IRSA 역할 (S3) | 특정 ServiceAccount에만 S3 접근 권한 부여 | `s3-access.tf`에 정의 |
| IRSA 역할 (EBS CSI) | EBS CSI 드라이버용 | `AmazonEBSCSIDriverPolicy` |

---

## 실습 순서

### 1단계: 초기화

```bash
cd 09_eks-cluster-mgmt/eks-cluster-with-irsa_pending
terraform init
```

### 2단계: 배포 (약 15~20분 소요)

```bash
terraform apply
```

### 3단계: kubeconfig 설정

```bash
aws eks update-kubeconfig \
  --name $(terraform output -raw cluster_name) \
  --region us-east-1 \
  --profile my-profile
```

### 4단계: IRSA 동작 확인

```bash
# S3 접근용 ServiceAccount에 연결된 어노테이션 확인
kubectl get serviceaccount -n default s3-access-sa -o yaml
# 출력 중 annotations에서 eks.amazonaws.com/role-arn 항목 확인
```

### 5단계: S3 접근 테스트 파드 실행

```bash
# S3 접근 테스트 파드 (aws cli 포함 이미지)
kubectl run s3-test \
  --image=amazon/aws-cli \
  --restart=Never \
  --serviceaccount=s3-access-sa \
  -- s3 ls
```

### 6단계: 리소스 삭제

```bash
terraform destroy
```

---

## IRSA 동작 원리

```
1. 파드가 ServiceAccount 토큰을 사용하여 AWS STS에 AssumeRoleWithWebIdentity 요청
2. EKS OIDC 프로바이더가 토큰 검증
3. STS가 IAM 역할의 임시 자격증명 발급
4. 파드가 해당 IAM 역할 권한으로 AWS 리소스 접근
```

---

## 변수 설명

| 변수명 | 설명 | 기본값 |
|--------|------|--------|
| `aws_region` | 리소스를 배포할 AWS 리전 | `"us-east-1"` |

---

## 비용 안내

> **주의:** 이 실습을 실행하면 AWS 비용이 발생합니다.

실습 종료 후 반드시 `terraform destroy`를 실행하세요.
