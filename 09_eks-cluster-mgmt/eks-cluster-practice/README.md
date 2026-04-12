# EKS 클러스터 기본 실습

## 실습 목표

이 실습을 통해 다음을 배울 수 있습니다:

- `terraform-aws-modules/eks` 모듈을 사용해 EKS 클러스터를 자동으로 구성하는 방법
- VPC, 서브넷, NAT 게이트웨이 등 EKS에 필요한 네트워크 인프라 구성
- EBS CSI 드라이버를 IRSA(IAM Roles for Service Accounts)와 함께 설정하는 방법
- TLS 프로바이더로 SSH 키 페어를 자동 생성하고 EC2 점프 호스트에 접속하는 방법

---

## 사전 요구 사항

| 도구 | 버전 | 확인 명령어 |
|------|------|------------|
| AWS CLI | 최신 | `aws --version` |
| Terraform | >= 1.13.4 | `terraform version` |
| kubectl | 최신 | `kubectl version --client` |

AWS CLI 프로파일 `my-profile`이 설정되어 있어야 합니다:

```bash
aws configure --profile my-profile
```

---

## 아키텍처 개요

```
인터넷
  │
  ▼
[퍼블릭 서브넷 x3] ── NAT 게이트웨이
  │
  ▼
[프라이빗 서브넷 x3]
  ├── EKS 관리형 노드 그룹 (c5.large x3)
  └── EC2 점프 호스트 (t3.micro) ── SSH 접속용
```

---

## 주요 리소스

| 리소스 | 설명 | 특이사항 |
|--------|------|---------|
| VPC (10.100.0.0/16) | EKS 전용 네트워크 환경 | 퍼블릭·프라이빗 서브넷 각 3개 |
| EKS 클러스터 (v1.34) | Kubernetes 클러스터 본체 | 퍼블릭 엔드포인트 활성화 |
| 관리형 노드 그룹 | 워커 노드 그룹 | c5.large, 최소 2 / 최대 10 |
| EBS CSI 드라이버 | Kubernetes PVC → EBS 볼륨 연결 | IRSA로 IAM 권한 연동 |
| IRSA IAM 역할 | EBS CSI 드라이버용 권한 | `AmazonEBSCSIDriverPolicy` 정책 연결 |
| EC2 인스턴스 (t3.micro) | kubectl 실행용 점프 호스트 | AL2023, 퍼블릭 IP 할당 |
| TLS 키 페어 | SSH 접속용 RSA 키 쌍 자동 생성 | `ec2-key.pem`으로 로컬에 저장 |

---

## 실습 순서

### 1단계: 초기화

```bash
cd 09_eks-cluster-mgmt/eks-cluster-practice
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

`yes`를 입력하면 배포가 시작됩니다.

### 4단계: kubeconfig 설정

배포 완료 후, 클러스터에 접속하기 위해 kubeconfig를 업데이트합니다:

```bash
# terraform output으로 클러스터 이름 확인
terraform output cluster_name

# kubeconfig 업데이트
aws eks update-kubeconfig \
  --name $(terraform output -raw cluster_name) \
  --region us-east-1 \
  --profile my-profile
```

### 5단계: 클러스터 상태 확인

```bash
# 노드 목록 확인 (3개 노드가 Ready 상태여야 함)
kubectl get nodes

# 파드 상태 확인
kubectl get pods -A

# EBS CSI 드라이버 확인
kubectl get pods -n kube-system | grep ebs-csi
```

### 6단계: EC2 점프 호스트 접속 (선택)

```bash
# 생성된 개인 키로 SSH 접속
ssh -i ec2-key.pem ec2-user@$(terraform output -raw ec2_public_ip)
```

### 7단계: 리소스 삭제 (실습 종료 후 반드시 실행)

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

| 리소스 | 예상 시간당 비용 |
|--------|----------------|
| EKS 클러스터 | ~$0.10 |
| c5.large 노드 x3 | ~$0.51 |
| NAT 게이트웨이 | ~$0.045 |
| EC2 t3.micro | ~$0.0104 |

실습 종료 후 반드시 `terraform destroy`를 실행하여 모든 리소스를 삭제하세요.
