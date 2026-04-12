# EKS 클러스터 수동 구성 실습 (모듈 없이)

## 실습 목표

이 실습을 통해 다음을 배울 수 있습니다:

- EKS 모듈에 의존하지 않고 AWS 네이티브 리소스(`aws_eks_cluster`, `aws_eks_node_group`)만으로 클러스터를 직접 구성하는 방법
- EKS 클러스터와 노드 그룹에 필요한 IAM 역할(클러스터 역할, 노드 역할)을 직접 생성하는 방법
- 수동 구성의 복잡성을 직접 경험하여, 실무에서 모듈을 써야 하는 이유를 체감

---

## ⚠️ 수동 구성의 한계 — 실무에서는 EKS 모듈을 쓰세요

이 프로젝트는 **학습 목적**으로 수동 구성 방식을 사용합니다.
실무(Best Practice)에서는 [`terraform-aws-modules/eks/aws`](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest) 모듈 사용을 강력히 권장합니다.

수동 구성에서 직접 처리해야 하는 것들이 얼마나 복잡한지 아래에서 확인하세요.

### 수동 구성이 어려운 이유

#### 1. OIDC 프로바이더 설정 (매우 어려움)

IRSA(IAM Roles for Service Accounts — 파드가 IAM 역할을 직접 사용하는 기능)를 쓰려면 OIDC 프로바이더를 직접 생성해야 합니다.

```hcl
# 수동으로 직접 해야 하는 것들:
# 1. OIDC issuer URL 추출
# 2. IAM OIDC 프로바이더 리소스 생성
# 3. 각 서비스 어카운트마다 신뢰 정책(Trust Policy)을 직접 작성

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}
```

EKS 모듈에서는 `enable_irsa = true` 한 줄로 끝납니다.

#### 2. EBS CSI 드라이버 연동 (복잡)

EBS 볼륨을 파드에서 쓰려면 EBS CSI 드라이버 애드온 + IRSA 역할 + 신뢰 정책을 모두 손으로 작성해야 합니다.
OIDC가 없으면 아예 시작도 못 하기 때문에 OIDC 설정 → IAM 역할 → 신뢰 정책 → 애드온 순서를 정확히 지켜야 합니다.

EKS 모듈에서는 `addons` 블록에 `service_account_role_arn`만 넣으면 됩니다.

#### 3. IAM 역할 3종 세트 (반복 작업)

| 역할 | 필요 정책 |
|------|----------|
| 클러스터 역할 | `AmazonEKSClusterPolicy` |
| 노드 역할 | `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly` |
| 애드온 역할 (예: EBS CSI) | 애드온별 정책 + OIDC 신뢰 정책 직접 작성 |

애드온이 늘어날수록 IAM 역할도 함께 늘어납니다. EKS 모듈은 이 모두를 자동으로 처리합니다.

#### 4. 보안 그룹 관리

클러스터 API 서버용 보안 그룹, 노드 간 통신 규칙 등을 직접 정의해야 합니다.
EKS 모듈은 권장 보안 그룹 규칙을 자동으로 생성합니다.

#### 5. 모듈 버전 업그레이드 대응

`aws_eks_cluster` 리소스의 API 변경이 생기면 직접 추적하고 수정해야 합니다.
EKS 모듈은 버전 업그레이드 시 하위 호환성 및 마이그레이션 가이드를 제공합니다.

### 모듈 방식과 수동 방식 비교

| 항목 | 모듈 사용 (권장) | 수동 구성 |
|------|----------------|----------|
| 코드 양 | 적음 | 많음 |
| OIDC/IRSA 설정 | `enable_irsa = true` 한 줄 | 수동으로 리소스 3~4개 작성 |
| EBS CSI 연동 | `addons` 블록에 ARN 지정 | OIDC → IAM → 애드온 순서 직접 관리 |
| 보안 그룹 | 자동 생성 | 직접 정의 |
| 유지보수 | 모듈 버전 올리면 끝 | 변경사항 직접 추적 |
| 실무 적합성 | **Best Practice** | 학습용 |

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
        └── aws_eks_cluster (v1.34)
              ├── aws_eks_node_group "node-group-1" (t3.small x2)
              └── aws_eks_node_group "node-group-2" (t3.small x1)

[IAM 역할]
  ├── eks-cluster-role       ── 클러스터 자체가 AWS API를 호출하는 데 필요
  └── eks-node-group-role    ── 워커 노드가 ECR, VPC 등에 접근하는 데 필요
```

---

## 실습 순서

### 1단계: 초기화

```bash
cd 09_eks-cluster-mgmt/manual-eks-cluster
terraform init
```

### 2단계: 리소스 변경 사항 미리 보기

```bash
terraform plan
```

### 3단계: 배포 (약 15~20분 소요)

```bash
terraform apply
```

### 4단계: kubeconfig 설정

```bash
aws eks update-kubeconfig \
  --name $(terraform output -raw cluster_name) \
  --region us-east-1 \
  --profile my-profile
```

### 5단계: 클러스터 상태 확인

```bash
# 노드 목록 확인 (3개 노드가 Ready 상태여야 함)
kubectl get nodes
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

---

## 비용 안내

> **주의:** 이 실습을 실행하면 AWS 비용이 발생합니다.

실습 종료 후 반드시 `terraform destroy`를 실행하세요.
