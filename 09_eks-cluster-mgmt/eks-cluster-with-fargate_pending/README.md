# EKS 클러스터 + AWS Fargate 실습

## 실습 목표

이 실습을 통해 다음을 배울 수 있습니다:

- AWS Fargate가 무엇인지, 일반 EC2 노드 그룹과 어떻게 다른지 이해
- Fargate 프로파일을 생성하여 특정 네임스페이스와 레이블의 파드를 서버리스로 실행하는 방법
- Fargate 파드 실행에 필요한 IAM 역할(Pod Execution Role) 구성 방법

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
[VPC 10.0.0.0/16]
  └── 프라이빗 서브넷 x3
        └── EKS 클러스터 (v1.34)
              ├── 관리형 노드 그룹 (EC2, c5.large) ── 일반 파드 실행
              └── Fargate 프로파일
                    └── "fargate-namespace" 네임스페이스의 파드 → Fargate로 실행

[Fargate 파드 조건]
  - 네임스페이스: fargate-namespace
  - 레이블: fargate_label=fargate-profile-a
```

---

## 주요 리소스

| 리소스 | 설명 | 특이사항 |
|--------|------|---------|
| EKS 클러스터 (v1.34) | Kubernetes 클러스터 | EC2 + Fargate 혼합 |
| 관리형 노드 그룹 | EC2 기반 워커 노드 | c5.large, On-demand |
| Fargate 프로파일 | 서버리스 파드 실행 | 네임스페이스+레이블 셀렉터로 적용 |
| Fargate Pod 실행 역할 | Fargate가 파드를 실행할 때 사용하는 IAM 역할 | `AmazonEKSFargatePodExecutionRolePolicy` |

---

## 실습 순서

### 1단계: 초기화

```bash
cd 09_eks-cluster-mgmt/eks-cluster-with-fargate_pending
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

### 4단계: Fargate 파드 실행 테스트

```bash
# Fargate용 네임스페이스 생성
kubectl create namespace fargate-namespace

# Fargate 파드 실행 (레이블 필수)
kubectl run fargate-test \
  --image=nginx \
  --namespace=fargate-namespace \
  --labels="fargate_label=fargate-profile-a"

# 파드가 Fargate에서 실행 중인지 확인 (node 이름에 fargate 포함)
kubectl get pods -n fargate-namespace -o wide
```

### 5단계: Fargate vs EC2 노드 비교

```bash
# 노드 목록 확인 (EC2 노드와 Fargate 노드 구분)
kubectl get nodes
```

### 6단계: 리소스 삭제

```bash
terraform destroy
```

---

## EC2 노드 그룹 vs Fargate 비교

| 항목 | EC2 노드 그룹 | AWS Fargate |
|------|--------------|-------------|
| 인프라 관리 | 직접 관리 | AWS 완전 관리 |
| 비용 | 노드 단위 | 파드 단위 |
| 스케일링 | 노드 추가/삭제 | 자동 |
| 상태 저장 파드 | 가능 | 제한적 |
| DaemonSet | 지원 | 미지원 |

---

## 변수 설명

| 변수명 | 설명 | 기본값 |
|--------|------|--------|
| `aws_region` | 리소스를 배포할 AWS 리전 | `"us-east-1"` |

---

## 비용 안내

> **주의:** 이 실습을 실행하면 AWS 비용이 발생합니다.

실습 종료 후 반드시 `terraform destroy`를 실행하세요.
