# EKS 클러스터 + Cluster Autoscaler 실습

## 실습 목표

이 실습을 통해 다음을 배울 수 있습니다:

- Kubernetes Cluster Autoscaler가 무엇인지, HPA(Horizontal Pod Autoscaler)와 어떻게 다른지 이해
- On-demand와 Spot 두 가지 노드 그룹을 혼합해 비용 효율적으로 클러스터 운영하는 방법
- Helm을 통해 Cluster Autoscaler를 EKS에 설치하고 IRSA로 권한을 연동하는 방법

> **참고:** 이 프로젝트는 실습 진행 중(_pending)인 버전입니다. 완성된 버전은 `eks-practice`를 참고하세요.

---

## 사전 요구 사항

| 도구 | 버전 | 확인 명령어 |
|------|------|------------|
| AWS CLI | 최신 | `aws --version` |
| Terraform | >= 1.13.4 | `terraform version` |
| kubectl | 최신 | `kubectl version --client` |
| Helm | >= 3.0 | `helm version` |

---

## 아키텍처 개요

```
[VPC 10.0.0.0/16]
  └── 프라이빗 서브넷 x3
        └── EKS 클러스터 (v1.34)
              ├── 노드 그룹: on_demand (capacity_type=SPOT, c5.large)
              └── 노드 그룹: on_spot   (capacity_type=SPOT, c5.large)

[Kubernetes 내부]
  └── Cluster Autoscaler (Helm 설치)
        └── IRSA 역할 ── AWS Auto Scaling 그룹 조정 권한
```

---

## 주요 리소스

| 리소스 | 설명 | 특이사항 |
|--------|------|---------|
| EKS 클러스터 (v1.34) | Kubernetes 클러스터 | 퍼블릭 엔드포인트 |
| 노드 그룹 on_demand | 일반 온디맨드 노드 | Spot 용량 타입, c5.large |
| 노드 그룹 on_spot | Spot 인스턴스 노드 | 비용 절감용 |
| Cluster Autoscaler | 노드 수를 자동으로 늘리고 줄임 | Helm으로 설치, IRSA 연동 |
| IRSA IAM 역할 | Autoscaler에게 Auto Scaling 권한 부여 | OIDC 신뢰 정책 |

---

## 실습 순서

### 1단계: 초기화

```bash
cd 09_eks-cluster-mgmt/eks-cluster-with-autoscaler_pending
terraform init
```

### 2단계: 배포 (약 20~25분 소요)

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

### 4단계: Cluster Autoscaler 확인

```bash
# Cluster Autoscaler 파드 확인
kubectl get pods -n kube-system | grep cluster-autoscaler

# Cluster Autoscaler 로그 확인
kubectl logs -n kube-system \
  $(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler -o name) \
  --tail=50
```

### 5단계: 자동 스케일링 테스트

```bash
# 부하 발생용 디플로이먼트 생성
kubectl create deployment stress-test --image=nginx --replicas=20

# 노드 수 증가 확인 (수 분 내에 새 노드가 추가됨)
kubectl get nodes -w
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

## Cluster Autoscaler vs HPA 비교

| 항목 | Cluster Autoscaler | HPA |
|------|--------------------|-----|
| 스케일 대상 | 노드(Node) | 파드(Pod) |
| 동작 조건 | 파드가 스케줄 불가 시 | CPU/메모리 사용률 초과 시 |
| 응답 속도 | 느림 (수 분) | 빠름 (수 십 초) |

---

## 비용 안내

> **주의:** 이 실습을 실행하면 AWS 비용이 발생합니다.

실습 종료 후 반드시 `terraform destroy`를 실행하세요.
