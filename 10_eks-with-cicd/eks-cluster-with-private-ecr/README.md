# EKS 클러스터 + Private ECR 실습

## 실습 목표

이 실습을 통해 다음을 배울 수 있습니다:

- Private ECR(Elastic Container Registry)과 EKS를 연동하는 방법
- EKS API 서버를 퍼블릭에 노출하지 않고 VPC 내부에서만 접근하도록 설정(프라이빗 엔드포인트) 하는 방법
- VPC 엔드포인트를 통해 ECR에 인터넷 없이 접근하는 방법
- EC2 점프 호스트에서 kubectl과 Docker를 사용하여 EKS와 ECR을 운용하는 방법

---

## 사전 요구 사항

| 도구 | 버전 | 확인 명령어 |
|------|------|------------|
| AWS CLI | 최신 | `aws --version` |
| Terraform | >= 1.13.4 | `terraform version` |
| kubectl | 최신 | `kubectl version --client` |
| Docker | 최신 | `docker version` |

---

## 아키텍처 개요

```
인터넷
  │
  ▼
[EC2 점프 호스트 (퍼블릭 서브넷)]
  │ SSH 접속 (ec2-key.pem)
  │
  ▼
[프라이빗 서브넷]
  ├── EKS 클러스터 (Private Endpoint만 활성화)
  │     └── 관리형 노드 그룹 (c5.large)
  └── VPC 엔드포인트
        ├── ECR API 엔드포인트
        └── ECR Docker 엔드포인트

[Private ECR 레지스트리]
  └── 컨테이너 이미지 저장소 (인터넷 없이 VPC 내에서 접근)
```

---

## 주요 리소스

| 리소스 | 설명 | 특이사항 |
|--------|------|---------|
| EKS 클러스터 (v1.34) | Private Endpoint 전용 클러스터 | `endpoint_public_access = false` |
| EC2 점프 호스트 (t3.micro) | 클러스터 접근용 | Docker + kubectl 자동 설치 |
| Private ECR 레지스트리 | 프라이빗 컨테이너 이미지 저장소 | `ecr.dkr.amazonaws.com` |
| VPC 엔드포인트 (ECR API) | ECR API 호출을 VPC 내부로 라우팅 | 보안 그룹: 443 포트 허용 |
| VPC 엔드포인트 (ECR Docker) | 이미지 push/pull을 VPC 내부로 라우팅 | 보안 그룹: 443 포트 허용 |
| TLS 키 페어 | EC2 SSH 접속용 RSA 키 자동 생성 | `ec2-key.pem`으로 로컬 저장 |

---

## 실습 순서

### 1단계: 초기화

```bash
cd 10_eks-with-cicd/eks-cluster-with-private-ecr
terraform init
```

### 2단계: 배포 (약 20~25분 소요)

```bash
terraform apply
```

### 3단계: EC2 점프 호스트 접속

```bash
# 점프 호스트 퍼블릭 IP 확인
terraform output ec2_public_ip

# SSH 접속
ssh -i ec2-key.pem ec2-user@$(terraform output -raw ec2_public_ip)
```

### 4단계: 점프 호스트에서 kubeconfig 설정

점프 호스트에 접속한 후 실행:

```bash
# kubeconfig 설정
aws eks update-kubeconfig \
  --name <클러스터 이름> \
  --region us-east-1 \
  --profile my-profile

# 노드 확인
kubectl get nodes
```

### 5단계: ECR에 이미지 Push/Pull 테스트

```bash
# ECR 로그인 (점프 호스트에서)
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  <계정ID>.dkr.ecr.us-east-1.amazonaws.com

# nginx 이미지를 ECR에 push
docker pull nginx:latest
docker tag nginx:latest <계정ID>.dkr.ecr.us-east-1.amazonaws.com/my-app:latest
docker push <계정ID>.dkr.ecr.us-east-1.amazonaws.com/my-app:latest
```

### 6단계: Private ECR 이미지로 파드 배포

```bash
# Private ECR 이미지 사용 파드 배포
kubectl run my-app \
  --image=<계정ID>.dkr.ecr.us-east-1.amazonaws.com/my-app:latest

# 파드 상태 확인
kubectl get pods
```

### 7단계: 리소스 삭제

```bash
terraform destroy
```

---

## 변수 설명

| 변수명 | 설명 | 기본값 |
|--------|------|--------|
| `aws_region` | 리소스를 배포할 AWS 리전 | `"us-east-1"` |

---

## Private Endpoint 사용 이유

Public EKS 엔드포인트를 비활성화하면:
- EKS API 서버가 인터넷에 노출되지 않아 보안 강화
- 모든 kubectl 명령은 VPC 내부에서만 가능 (점프 호스트 필요)
- 기업 보안 정책 준수에 적합

---

## 비용 안내

> **주의:** 이 실습을 실행하면 AWS 비용이 발생합니다.

| 리소스 | 예상 시간당 비용 |
|--------|----------------|
| EKS 클러스터 | ~$0.10 |
| c5.large 노드 x2 | ~$0.34 |
| NAT 게이트웨이 | ~$0.045 |
| VPC 엔드포인트 x2 | ~$0.02 |
| EC2 t3.micro | ~$0.0104 |

실습 종료 후 반드시 `terraform destroy`를 실행하세요.
