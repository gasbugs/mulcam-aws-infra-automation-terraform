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
  └── EKS 클러스터 (v1.35)
        ├── 시스템 노드 그룹 (m5.large × 2)  ── CriticalAddonsOnly Taint
        │     └── Karpenter 컨트롤러, CoreDNS, EKS Addon 전용
        └── Karpenter로 동적 생성되는 노드들  ── 애플리케이션 파드 배치

[Karpenter 구성]
  ├── EC2NodeClass  ── 어떤 AMI/서브넷/보안 그룹을 쓸지 정의 (nodeclasses.yaml)
  ├── NodePool      ── 어떤 인스턴스 타입을 쓸지, 몇 개까지 만들지 정의 (nodepool.yaml)
  └── Helm Chart    ── Karpenter 컨트롤러 v1.0.6 설치
```

### Taint 동작 원리

```
시스템 노드 그룹
  taint: CriticalAddonsOnly=true:NoSchedule
  → Karpenter/CoreDNS 파드만 tolerates → 이 노드에서 실행

일반 파드(nginx 등)
  tolerations 없음 → 시스템 노드 스케줄 불가
  → Karpenter가 새 노드를 자동 프로비저닝 → 새 노드에 배치
```

---

## 주요 리소스

| 리소스 | 설명 | 특이사항 |
|--------|------|---------|
| EKS 클러스터 (v1.35) | Kubernetes 클러스터 | CriticalAddonsOnly Taint 노드 그룹 |
| Karpenter 모듈 | IAM 역할, SQS 큐 등 인프라 준비 | Pod Identity 방식 |
| Helm Release | Karpenter 컨트롤러 v1.0.6 | ECR Public 레지스트리 |
| EC2NodeClass | 노드 이미지(AMI), 네트워크 설정 | `nodeclasses.yaml` — Terraform이 templatefile()로 주입 |
| NodePool | 허용 인스턴스, 최대 용량 설정 | `nodepool.yaml` — c/m/r 계열, 최대 1000 vCPU |
| SSM Parameter | 최신 AL2023 EKS AMI ID 동적 조회 | v1.35 버전 경로 자동 참조 |

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

> Terraform이 다음 순서로 자동 처리합니다:
> 1. VPC + EKS 클러스터 생성
> 2. 시스템 노드 그룹 (m5.large × 2) 생성
> 3. CoreDNS Addon 설치
> 4. Karpenter 모듈 (SQS, IAM, Pod Identity) 생성
> 5. Karpenter Helm 차트 설치
> 6. EC2NodeClass (`nodeclasses.yaml`) 적용 — AMI ID, IAM 역할, 서브넷/보안 그룹 태그 주입
> 7. NodePool (`nodepool.yaml`) 적용 — c/m/r 계열 인스턴스, nitro 하이퍼바이저 선택 기준

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

# NodeClass 확인 — Terraform이 nodeclasses.yaml을 적용해 자동 생성
kubectl get ec2nodeclasses

# NodePool 확인 — Terraform이 nodepool.yaml을 적용해 자동 생성
kubectl get nodepools

# 현재 노드 목록 (시스템 노드 그룹 2개만 존재해야 정상)
kubectl get nodes
```

### 5단계: Karpenter 오토스케일링 테스트

`karpenter_example_deployment.yaml`은 Karpenter의 노드 프로비저닝을 직접 검증하는 테스트 Deployment입니다.

**테스트 구성:**
- nginx 파드 5개, 각 파드 CPU 1개 요청
- `podAntiAffinity` (requiredDuringScheduling, topologyKey: hostname) 적용
  → 모든 파드가 **서로 다른 노드**에 배치되어야 함
- 시스템 노드는 `CriticalAddonsOnly` taint로 일반 파드 스케줄 불가
  → Karpenter가 새 EC2 노드 5개를 자동 프로비저닝

```bash
# 테스트 Deployment 배포
kubectl apply -f karpenter_example_deployment.yaml

# Karpenter가 노드를 프로비저닝하는 과정 관찰 (새 노드들이 등장해야 정상)
kubectl get nodes -w

# 파드 스케줄 상태 확인 (Pending → Running 전환 확인)
kubectl get pods -l app=my-app -w

# NodeClaim 목록 — Karpenter가 요청한 노드 목록
kubectl get nodeclaims

# Karpenter 컨트롤러 로그 (프로비저닝 이유 확인)
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=30
```

**테스트 후 정리 (Consolidation 확인):**

```bash
# Deployment 삭제 → 파드 제거 → 노드 비어있음
kubectl delete -f karpenter_example_deployment.yaml

# NodePool consolidateAfter: 30s 설정으로 30초 후 빈 노드 자동 삭제
# 노드가 줄어드는 과정 관찰
kubectl get nodes -w
```

### 6단계: 리소스 삭제

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
