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
| 노드 그룹 on_demand | 온디맨드 인스턴스 노드 | 온디맨드 용량 타입, c5.large |
| 노드 그룹 on_spot | Spot 인스턴스 노드 | 비용 절감용, c5.large |
| Cluster Autoscaler | 노드 수를 자동으로 늘리고 줄임 | Helm으로 설치, IRSA 연동 |
| IRSA IAM 역할 | Autoscaler에게 Auto Scaling 권한 부여 | OIDC 신뢰 정책 |

---

## 실습 순서

### 1단계: 초기화

```bash
cd 09_eks-cluster-mgmt/eks-cluster-with-autoscaler_pending
terraform init
```

### 2단계: 1차 배포 — VPC + EKS + 노드 그룹 (약 20분 소요)

Helm/Kubernetes 프로바이더는 EKS 클러스터가 준비된 후에 연결할 수 있으므로
인프라 리소스를 먼저 배포합니다.

```bash
terraform apply \
  -target=module.vpc \
  -target=module.eks \
  -target=module.eks_managed_node_group_on_demand \
  -target=module.eks_managed_node_group_on_spot
```

### 3단계: kubeconfig 설정

```bash
aws eks update-kubeconfig \
  --name $(terraform output -raw cluster_name) \
  --region us-east-1 \
  --profile my-profile
```

### 4단계: 2차 배포 — Cluster Autoscaler 설치 (약 2분 소요)

kubeconfig 설정 완료 후 나머지 Kubernetes/Helm 리소스를 배포합니다.

```bash
terraform apply
```

### 5단계: Cluster Autoscaler 확인

```bash
# Cluster Autoscaler 파드 확인
kubectl get pods -n kube-system | grep cluster-autoscaler

# Cluster Autoscaler 로그 확인
kubectl logs -n kube-system \
  $(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler -o name) \
  --tail=50
```

### 6단계: 자동 스케일링 테스트

```bash
# 부하 발생용 디플로이먼트 생성 (CPU 요청을 명시해야 스케일 아웃 트리거됨)
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stress-test
spec:
  replicas: 20
  selector:
    matchLabels:
      app: stress-test
  template:
    metadata:
      labels:
        app: stress-test
    spec:
      containers:
      - name: app
        image: nginx
        resources:
          requests:
            cpu: "500m"
            memory: "256Mi"
EOF

# 노드 수 증가 확인 (수 분 내에 새 노드가 추가됨)
kubectl get nodes -w
```

### 7단계: 리소스 삭제

```bash
# 테스트 리소스 먼저 삭제
kubectl delete deployment stress-test

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
