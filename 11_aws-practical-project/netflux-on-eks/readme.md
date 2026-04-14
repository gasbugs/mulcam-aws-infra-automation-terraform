# Terraform을 활용한 NetFlux on EKS 실전 구성 실습

Terraform을 사용하여 netflux-app을 빌드하고 EKS에 배포할 수 있는 환경을 구성합니다.

---

## 아키텍처 구조

```
CodeCommit (netflux-app)
  │ push → EventBridge 이벤트 감지
  ▼
CodePipeline
  │ Source → Build
  ▼
CodeBuild → ECR (Docker 이미지)
  │ deployment.yaml 이미지 주소 자동 업데이트
  ▼
CodeCommit (netflux-deploy)
  │ ArgoCD가 변경 감지
  ▼ ArgoCD (GitOps)
EKS Cluster
  │ netflux 파드 (Flask App)
  │    └── DynamoDB (Movies 테이블)
  ▼
CLB (Kubernetes LoadBalancer Service)
  │
  ▼
CloudFront
  ├── *.jpg 요청 → S3 (영화 포스터 이미지)
  └── 그 외 요청 → EKS CLB (Flask App)
```

---

## 요구사항

### 1. CI/CD 파이프라인 설정

AWS를 사용하여 CI/CD 파이프라인을 구축합니다.

1. **CodeCommit 저장소 2개**: netflux-app(소스 코드), netflux-deploy(배포 매니페스트)
2. **S3 버킷**: 파이프라인 아티팩트 저장용 (삭제 시 모든 객체도 함께 삭제)
3. **CloudWatch 로그 그룹**: CodeBuild 빌드 로그 저장용
4. **ECR 리포지토리**: Docker 이미지 저장소
5. **IAM 역할 및 정책**: CodePipeline, CodeBuild, CodeCommit, Events 서비스용
6. **CodeBuild 프로젝트**: VPC 설정 및 보안 그룹 포함, buildspec.yml 실행
7. **EventBridge 규칙**: netflux-app main 브랜치 push 시 파이프라인 자동 트리거
8. **CodePipeline**: Source(CodeCommit) → Build(CodeBuild) 구성

### 2. CloudFront + S3 (정적 콘텐츠 CDN)

| 항목 | 설정 |
|---|---|
| CloudFront 오리진 1 | S3 버킷 (OAC 방식으로 보안 접근) |
| CloudFront 오리진 2 | EKS CLB |
| 기본 캐시 동작 | EKS CLB로 라우팅 |
| 경로 기반 라우팅 | `*.jpg` → S3로 라우팅 |
| S3 버킷 정책 | CloudFront에서만 접근 가능 |
| 버킷 이름 | 랜덤 숫자 접미사 추가 |

### 3. DynamoDB 구성

| 항목 | 설정 |
|---|---|
| 테이블 이름 | Movies |
| 파티션 키 | title (String) |
| 정렬 키 | year (Number) |
| 빌링 모드 | PROVISIONED (읽기/쓰기 각 5) |
| VPC 엔드포인트 타입 | Interface |
| 보안 그룹 | VPC 내부 HTTPS(443) 허용 |

### 4. EKS 클러스터 구성 및 IRSA 설정

| 항목 | 설정 |
|---|---|
| EKS 버전 | 1.32 |
| 노드 인스턴스 유형 | c5.large |
| 노드 수 | 최소 1, 최대 3, 기본 2 |
| EKS 모듈 내 애드온 | vpc-cni, kube-proxy, eks-pod-identity-agent |
| 별도 배포 애드온 | coredns, aws-ebs-csi-driver (노드 그룹 후) |
| IRSA 1 | EBS CSI 드라이버용 |
| IRSA 2 | DynamoDB 접근용 (netflux-sa 서비스 계정) |
| GitOps 도구 | ArgoCD (Helm 설치) |

> **중요**: 노드 그룹은 EKS 모듈과 반드시 분리하여 배포합니다.  
> DaemonSet 기반 애드온(vpc-cni 등)은 EKS 모듈 내에, Deployment 기반(coredns 등)은 별도 리소스로 구성합니다.

### 5. Kubernetes 서비스 (CLB)

| 항목 | 설정 |
|---|---|
| 네임스페이스 | netflux |
| 서비스 이름 | netflux-svc |
| 서비스 타입 | LoadBalancer (CLB 자동 생성) |
| 포트 매핑 | 80 → 5000 (Flask) |
| 서비스 계정 | netflux-sa (DynamoDB IRSA 연결) |

---

## 파일 구조

```
wordpress-on-eks/
├── netflux-app/           # Flask 애플리케이션 소스 코드
│   ├── source/
│   │   ├── app.py          # Flask 앱 (DynamoDB 연동)
│   │   ├── static/         # 영화 포스터 이미지
│   │   └── templates/      # HTML 템플릿
│   └── Dockerfile          # Docker 이미지 빌드 파일
├── netflux-deploy/        # Kubernetes 배포 매니페스트
│   └── deployment.yaml     # ArgoCD가 참조하는 K8s Deployment
└── netflux-on-eks/        # Terraform 인프라 코드
    ├── provider.tf         # AWS, Helm, Kubernetes, Time, Random 프로바이더
    ├── vars_locals.tf      # 변수, 로컬, 랜덤 리소스
    ├── vpc.tf              # VPC 모듈 (3 AZ, 퍼블릭/프라이빗 서브넷)
    ├── eks.tf              # EKS 클러스터, 노드 그룹, 애드온, IRSA, ArgoCD
    ├── cicd.tf             # CodePipeline, CodeBuild, ECR, Webhook
    ├── cloudfront_s3.tf    # CloudFront, S3, OAC
    ├── dynamodb.tf         # DynamoDB 테이블, VPC 엔드포인트
    ├── clb.tf              # Kubernetes 네임스페이스, 서비스
    ├── random-suffix.tf    # S3 버킷 이름 고유화용 랜덤 숫자
    └── outputs.tf          # GitHub Webhook URL, Secret 출력
```

---

## 배포 방법

```bash
# 1. 작업 디렉터리로 이동
cd netflux-on-eks

# 2. 초기화
terraform init

# 3. 배포 (약 20~30분 소요)
terraform apply -auto-approve
```

### 배포 후 추가 설정

**netflux-app 소스 코드를 CodeCommit에 push**:
```bash
# terraform output으로 CodeCommit 저장소 주소 확인
terraform output netflux_app_codecommit_url

# netflux-app 디렉터리를 CodeCommit에 push
cd ../netflux-app
git init
git add .
git commit -m "initial commit"
git remote add origin <netflux_app_codecommit_url>
git push -u origin main
```
> push가 완료되면 EventBridge가 감지하여 CodePipeline이 자동으로 실행됩니다.

**netflux-deploy 매니페스트를 CodeCommit에 push**:
```bash
# netflux-deploy 디렉터리를 CodeCommit에 push (ArgoCD가 이 저장소를 감시)
cd ../netflux-deploy
git init
git add .
git commit -m "initial commit"
git remote add origin <netflux_deploy_codecommit_url>
git push -u origin main
```

**실패한 파이프라인 재시작**:
```bash
aws codepipeline start-pipeline-execution --name <파이프라인-이름>
```

**ArgoCD 접속 주소 확인**:
```bash
kubectl get svc -n argocd
```

**ArgoCD에서 netflux-deploy 저장소 연결**:
1. ArgoCD UI 접속 (admin / 초기 비밀번호 확인)
2. Settings → Repositories → HTTPS 방식으로 netflux-deploy CodeCommit 주소 입력
3. Applications → New App → Path: `.` / Branch: `main` 설정 후 생성

**배포 확인**:
```bash
kubectl get pod,svc,sa -n netflux
```

예상 출력:
```
NAME                           READY   STATUS    RESTARTS   AGE
pod/netflux-6cfc568c78-xxxxx   1/1     Running   0          5m

NAME                  TYPE           CLUSTER-IP       EXTERNAL-IP       PORT(S)        AGE
service/netflux-svc   LoadBalancer   172.20.x.x       <CLB-HOSTNAME>    80:xxxxx/TCP   10m

NAME                      SECRETS   AGE
serviceaccount/netflux-sa   0       10m
```

---

## 동작 확인

### CLB 직접 접근
```
http://<CLB-HOSTNAME>
```
→ 영화 목록은 보이지만 이미지(`.jpg`)는 S3를 통하지 않아 로드되지 않음

### CloudFront 접근
```
https://<CloudFront-Domain>
```
→ `*.jpg` 요청이 S3로 라우팅되어 영화 포스터 이미지가 정상 표시

---

## 리소스 정리

```bash
# Kubernetes 로드밸런서 먼저 삭제 (CLB 삭제 대기)
terraform destroy -target helm_release.argocd -auto-approve
terraform destroy -target kubernetes_service_v1.netflux_svc -auto-approve

# 전체 리소스 삭제
terraform destroy -auto-approve
```

---

## 풀이 요약

### 핵심 구현 포인트

1. **EKS 모범사례 적용**:
   - 노드 그룹은 EKS 모듈과 별도 `eks-managed-node-group` 모듈로 분리
   - DaemonSet 기반 애드온(vpc-cni, kube-proxy)만 EKS 모듈 내 설정
   - Deployment 기반 애드온(coredns, ebs-csi)은 `aws_eks_addon` 별도 리소스로 노드 그룹 후 설치

2. **IRSA 구성**: IAM 역할과 Kubernetes 서비스 계정을 OIDC로 연결하여 파드가 AWS 서비스에 영구 자격증명 없이 접근

3. **GitOps (ArgoCD)**: netflux-deploy 저장소의 변경사항을 EKS 클러스터에 자동 반영

4. **멀티 오리진 CloudFront**: S3(정적 이미지)와 EKS CLB(동적 컨텐츠)를 경로 기반으로 분리

5. **DynamoDB VPC 엔드포인트**: Interface 타입으로 VPC 내부에서 프라이빗 DNS를 통해 DynamoDB 접근

### 주요 Terraform 리소스 대응

| AWS/K8s 서비스 | Terraform 리소스 |
|---|---|
| EKS 클러스터 | `module "eks"` |
| EKS 노드 그룹 | `module "eks_managed_node_groups"` (분리) |
| CoreDNS, EBS CSI | `aws_eks_addon` (노드 그룹 후 설치) |
| IRSA | `module "irsa-ebs-csi"`, `module "dynamodb_irsa_role"` |
| ArgoCD | `helm_release.argocd` |
| CodePipeline | `aws_codepipeline` |
| CodeBuild | `aws_codebuild_project` |
| ECR | `aws_ecr_repository` |
| CloudFront | `aws_cloudfront_distribution` |
| DynamoDB | `aws_dynamodb_table` |
| K8s Namespace | `kubernetes_namespace_v1` |
| K8s Service (CLB) | `kubernetes_service_v1` |
| K8s ServiceAccount | `kubernetes_service_account_v1` |
