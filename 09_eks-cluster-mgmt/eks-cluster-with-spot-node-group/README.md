# EKS 클러스터 + Spot 인스턴스 노드 그룹 실습

## 실습 목표

이 실습을 통해 다음을 배울 수 있습니다:

- AWS Spot 인스턴스가 On-demand 대비 최대 90% 저렴하지만 언제든 회수될 수 있다는 특성 이해
- EKS 모듈 클러스터에 네이티브 `aws_eks_node_group`을 추가로 붙이는 혼합 구성 방법
- Spot 인스턴스를 중단 내성(Interrupt Tolerant)이 있는 워크로드에 적용하는 전략

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
  ├── 관리형 노드 그룹 (On-demand, c5.large) ── 안정적인 워크로드
  └── 추가 노드 그룹 (Spot, c5.large)         ── 비용 절감 워크로드
        └── aws_eks_node_group (네이티브 리소스로 추가)
```

---

## 주요 리소스

| 리소스 | 설명 | 특이사항 |
|--------|------|---------|
| EKS 클러스터 (v1.34) | 기본 EKS 클러스터 | EKS 모듈로 생성 |
| On-demand 노드 그룹 | 안정적인 기본 노드 | 중단 없는 워크로드용 |
| Spot 노드 그룹 | 비용 절감 Spot 노드 | `aws_eks_node_group` 네이티브 리소스 |
| Spot 노드 IAM 역할 | 노드가 AWS 서비스 접근 시 사용 | Worker, CNI, ECR 정책 연결 |

---

## 실습 순서

### 1단계: 초기화

```bash
cd 09_eks-cluster-mgmt/eks-cluster-with-spot-node-group_pending
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

### 4단계: 노드 타입 확인

```bash
# 노드 목록 및 capacity-type 레이블 확인
kubectl get nodes -L eks.amazonaws.com/capacityType

# On-demand와 Spot 노드 구분
kubectl get nodes --show-labels | grep -E "capacityType"
```

### 5단계: Spot 노드에 파드 스케줄링 테스트

```bash
# Spot 노드를 선호하는 파드 배포 (Node Selector 사용)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: spot-test
spec:
  nodeSelector:
    eks.amazonaws.com/capacityType: SPOT
  containers:
  - name: nginx
    image: nginx
EOF
```

### 6단계: 리소스 삭제

```bash
terraform destroy
```

---

## Spot 인스턴스 사용 권장 워크로드

| 적합한 워크로드 | 부적합한 워크로드 |
|---------------|-----------------|
| 배치 처리, 데이터 분석 | 데이터베이스, 상태 저장 앱 |
| CI/CD 빌드 워커 | 실시간 트랜잭션 처리 |
| ML/AI 학습 작업 | 고가용성 필수 서비스 |
| 개발/테스트 환경 | 운영 웹 서버 |

---

## 변수 설명

| 변수명 | 설명 | 기본값 |
|--------|------|--------|
| `aws_region` | 리소스를 배포할 AWS 리전 | `"us-east-1"` |

---

## 비용 안내

> **주의:** 이 실습을 실행하면 AWS 비용이 발생합니다.

Spot 인스턴스는 On-demand 대비 저렴하지만, 실습 종료 후 반드시 `terraform destroy`를 실행하세요.
