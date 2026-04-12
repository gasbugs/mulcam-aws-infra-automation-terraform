# EKS 클러스터 + 커스텀 VPC 실습

## 실습 목표

이 실습을 통해 다음을 배울 수 있습니다:

- 기본 VPC 대신 목적에 맞는 CIDR 블록과 서브넷 구조를 직접 설계하는 방법
- 여러 개의 관리형 노드 그룹을 서로 다른 용도(웹, 배치 등)로 분리하는 방법
- 실제 운영 환경에서 자주 사용되는 VPC 태깅(ELB 연동) 전략 이해

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
[커스텀 VPC]
  ├── 퍼블릭 서브넷 x3  ─── ALB(Application Load Balancer) 배포 가능
  └── 프라이빗 서브넷 x3 ─── EKS 노드 배포
        └── EKS 클러스터 (v1.34)
              ├── 노드 그룹 1 (on_demand) ── 일반 워크로드
              └── 노드 그룹 2 (spot)      ── 비용 절감용 Spot 인스턴스
```

---

## 주요 리소스

| 리소스 | 설명 | 특이사항 |
|--------|------|---------|
| VPC | 커스텀 CIDR 구성 | CIDR, 서브넷 구조 직접 확인 권장 |
| EKS 클러스터 (v1.34) | Kubernetes 클러스터 | 퍼블릭 엔드포인트 활성화 |
| 관리형 노드 그룹 | 목적별로 분리된 노드 그룹 | t3.small, 각 그룹 독립 스케일링 |
| EBS CSI 드라이버 | EBS 볼륨 동적 프로비저닝 | IRSA 연동 |

---

## 실습 순서

### 1단계: 초기화

```bash
cd 09_eks-cluster-mgmt/eks-cluster-with-custom-vpc
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
# 노드 그룹 확인
kubectl get nodes --show-labels

# 노드별 레이블 확인 (노드 그룹 구분)
kubectl get nodes -o wide
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
