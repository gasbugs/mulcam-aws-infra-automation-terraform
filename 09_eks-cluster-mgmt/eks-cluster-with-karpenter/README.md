# EKS 클러스터 + Karpenter 실습 (직접 구성 버전)

## 실습 목표

이 실습을 통해 다음을 배울 수 있습니다:

- `eks-practice`의 완성된 코드를 참고하면서, 빈 구조에 직접 코드를 채워 넣는 실습
- Karpenter의 각 구성 요소(NodeClass, NodePool, Helm Release)를 직접 작성하면서 이해하는 방법

> **참고:** 이 프로젝트는 `eks-practice`의 실습 버전입니다.
> 완성된 참조 코드는 `eks-practice` 디렉토리를 확인하세요.

---

## 사전 요구 사항

| 도구 | 버전 | 확인 명령어 |
|------|------|------------|
| AWS CLI | 최신 | `aws --version` |
| Terraform | >= 1.13.4 | `terraform version` |
| kubectl | 최신 | `kubectl version --client` |
| Helm | >= 2.7 | `helm version` |

---

## 아키텍처 개요

```
[VPC]
  └── EKS 클러스터 (v1.34)
        ├── 초기 노드 그룹 (m5.large) ── Karpenter 컨트롤러 실행
        └── Karpenter로 동적 생성되는 노드들

[Karpenter 구성]
  ├── NodeClass  ── 어떤 AMI/서브넷/보안 그룹을 쓸지 정의
  ├── NodePool   ── 어떤 인스턴스 타입을 쓸지, 몇 개까지 만들지 정의
  └── Helm Chart ── Karpenter 컨트롤러 설치
```

---

## 주요 리소스

| 리소스 | 설명 | 특이사항 |
|--------|------|---------|
| EKS 클러스터 (v1.34) | Kubernetes 클러스터 | Karpenter 전용 Taint 노드 그룹 |
| Karpenter 모듈 | IAM 역할, SQS 큐 등 인프라 준비 | Pod Identity 방식 |
| Helm Release | Karpenter 컨트롤러 v1.0.6 | ECR Public 레지스트리 |
| EC2NodeClass | 노드 이미지(AMI), 네트워크 설정 | nodeclasses.yaml |
| NodePool | 허용 인스턴스, 최대 용량 설정 | nodepool.yaml |
| SSM Parameter | 최신 AL2023 EKS AMI ID 동적 조회 | v1.34 버전 경로 |

---

## 실습 순서

### 1단계: 초기화

```bash
cd 09_eks-cluster-mgmt/eks-cluster-with-karpenter
terraform init
```

### 2단계: 배포 (약 20~25분 소요)

Helm/kubectl 프로바이더가 `exec` 방식으로 EKS에 직접 인증하므로
단일 `terraform apply`로 전체 리소스를 한 번에 배포합니다.

```bash
terraform apply
```

### 3단계: kubeconfig 설정

`kubectl`을 직접 사용하려면 kubeconfig를 업데이트합니다.

```bash
aws eks update-kubeconfig \
  --name $(terraform output -raw cluster_name) \
  --region us-east-1 \
  --profile my-profile
```

### 4단계: Karpenter 동작 확인

```bash
# Karpenter 파드 실행 확인 (2개 Running이어야 정상)
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

# NodeClass 확인
kubectl get ec2nodeclasses

# NodePool 확인
kubectl get nodepools
```

### 5단계: 리소스 삭제

```bash
# Karpenter가 관리하는 노드 먼저 정리 (남아있으면 destroy 중 재생성 시도 가능)
kubectl delete nodeclaims --all
kubectl delete nodepools --all

terraform destroy
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
