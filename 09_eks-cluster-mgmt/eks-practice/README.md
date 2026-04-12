# EKS 클러스터 + Karpenter 오토스케일러 실습

## 실습 목표

이 실습을 통해 다음을 배울 수 있습니다:

- Karpenter가 기존 Cluster Autoscaler와 어떻게 다른지 이해 (노드 프로비저닝 방식 차이)
- Karpenter NodeClass와 NodePool을 정의하여 자동 노드 생성 규칙을 설정하는 방법
- EFS 파일 스토리지와 EBS 블록 스토리지를 함께 사용하는 멀티 스토리지 구성
- AWS SSM Parameter Store를 통한 EKS 최적화 AMI 동적 조회 방법

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
[VPC (인트라 서브넷 포함)]
  └── 프라이빗 서브넷 x3
        └── EKS 클러스터 (v1.34)
              ├── Karpenter 전용 노드 그룹 (m5.large)
              │     └── Karpenter 컨트롤러 실행
              └── Karpenter가 동적 생성하는 노드들
                    └── NodeClass/NodePool 규칙 기반

[Karpenter 구성]
  ├── NodeClass  ── AMI, 서브넷, 보안 그룹 등 노드 설정
  └── NodePool   ── 인스턴스 타입, 용량 타입, 리소스 한도
```

---

## 주요 리소스

| 리소스 | 설명 | 특이사항 |
|--------|------|---------|
| EKS 클러스터 (v1.34) | Kubernetes 클러스터 | Karpenter 전용 노드 그룹 포함 |
| Karpenter 모듈 | 노드 오토스케일러 설치 도구 | Pod Identity 방식으로 IAM 연동 |
| Helm Release (karpenter) | Karpenter 컨트롤러 설치 | v1.0.6 |
| kubectl_manifest (NodeClass) | AMI, 서브넷, 보안 그룹 정의 | SSM으로 AL2023 AMI 동적 조회 |
| kubectl_manifest (NodePool) | 허용 인스턴스 타입, 최대 노드 수 | `nodepool.yaml` 참조 |
| EFS 파일시스템 | 여러 파드에서 공유하는 스토리지 | 암호화, 마운트 타겟 x3 |
| IRSA (EBS/EFS CSI) | CSI 드라이버용 IAM 권한 | OIDC 신뢰 정책 |

---

## 실습 순서

### 1단계: 초기화

```bash
cd 09_eks-cluster-mgmt/eks-practice
terraform init
```

### 2단계: 리소스 변경 사항 미리 보기

```bash
terraform plan
```

### 3단계: 배포 (약 25~30분 소요)

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

### 5단계: Karpenter 상태 확인

```bash
# Karpenter 파드 확인
kubectl get pods -n kube-system | grep karpenter

# NodeClass 확인
kubectl get ec2nodeclasses

# NodePool 확인
kubectl get nodepools
```

### 6단계: Karpenter 자동 스케일링 테스트

```bash
# 큰 리소스 요청 파드 배포 (새 노드가 자동 생성됨)
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: karpenter-test
spec:
  replicas: 5
  selector:
    matchLabels:
      app: karpenter-test
  template:
    metadata:
      labels:
        app: karpenter-test
    spec:
      containers:
      - name: app
        image: nginx
        resources:
          requests:
            cpu: "1"
            memory: "1Gi"
EOF

# 새 노드 생성 확인
kubectl get nodes -w
```

### 7단계: 리소스 삭제

```bash
# 배포한 테스트 리소스 먼저 삭제
kubectl delete deployment karpenter-test

terraform destroy
```

---

## Karpenter vs Cluster Autoscaler 비교

| 항목 | Karpenter | Cluster Autoscaler |
|------|-----------|-------------------|
| 노드 결정 방식 | 파드 요구사항 분석 후 최적 인스턴스 선택 | 기존 노드 그룹 내에서만 조정 |
| 응답 속도 | 빠름 (< 1분) | 느림 (수 분) |
| 인스턴스 다양성 | 매우 유연 | 노드 그룹별 고정 |
| 비용 최적화 | 뛰어남 | 보통 |

---

## 변수 설명

| 변수명 | 설명 | 기본값 |
|--------|------|--------|
| `aws_region` | 리소스를 배포할 AWS 리전 | `"us-east-1"` |

---

## 비용 안내

> **주의:** 이 실습을 실행하면 AWS 비용이 발생합니다.

실습 종료 후 반드시 `terraform destroy`를 실행하세요.
