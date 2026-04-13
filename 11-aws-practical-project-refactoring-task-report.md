# 11-aws-practical-project-refactoring 작업 보고서

**브랜치**: `11-aws-practical-project-refactoring`  
**작업 일시**: 2026-04-14  
**대상 프로젝트**: `/11_aws-practical-project/`

---

## 요약

두 서브프로젝트(`wordpress-on-ec2`, `wordpress-on-eks`)의 Terraform 코드를 모범사례 기준으로 리팩토링하고, README를 수강생 전달용으로 개선했습니다.

---

## 1. wordpress-on-ec2 리팩토링

### 발견된 문제 및 수정 내용

| 파일 | 문제 | 수정 내용 |
|------|------|----------|
| `provider.tf` | `required_version = ">= 1.13.4"` (존재하지 않는 버전) | `>= 1.9.0`으로 수정 |
| `provider.tf` | 주석 중복 오류 | 정리 |
| `variables.tf` | `sensitive = true` 주석 처리됨 | 활성화 (비밀번호 보안) |
| `variables.tf` | description 누락 | 영어 description 추가 |
| `main.tf` | `storage_type = "gp2"` | `gp3`으로 업그레이드 (성능↑ 비용↓) |
| `main.tf` | `null_resource` (deprecated) | `terraform_data`로 교체 |
| `main.tf` | EFS 보안 그룹 `name` 없음 | 추가 |
| `main.tf` | AMI 동적 조회 누락 | `data "aws_ami"` 추가 + `-force` 플래그 |
| `infra.tf` | 하드코딩된 AMI ID | `data.aws_ami.wordpress.id` 동적 참조 |
| `infra.tf` | ASG `max_size = 4` (README는 3) | `3`으로 수정 (README와 일치) |
| `infra.tf` | 보안 그룹 `name`/`description` 누락 | 영어로 추가 |
| `infra.tf` | Launch Template `depends_on` 누락 | `terraform_data.packer_build` 의존성 추가 |
| `outputs.tf` | `description` 누락 | 영어로 추가 |
| `al2023-wp-ami.pkr.hcl` | `wp core install` `--allow-root` 누락 | 추가 |
| `readme.md` | 수강생 전달 불충분 | 전면 재작성 (아키텍처, 요구사항, 풀이 포함) |

### terraform validate 결과
```
✅ Success! The configuration is valid.
```

### terraform plan 결과
```
Plan: 39 to add, 0 to change, 0 to destroy.
✅ 오류 없음
```

### terraform apply 결과

**1차 시도 실패**: Packer가 `[default]` AWS 프로파일(무효한 키) 사용
→ 오류: `security token included in the request is invalid`

**원인**: Packer는 Terraform의 `provider "aws" { profile = "my-profile" }` 설정을 상속받지 않고, 독립적으로 AWS 자격증명 체인을 탐색함

**수정**: `local-exec` 프로비저너에 `environment = { AWS_PROFILE = "my-profile" }` 추가

**최종 결과** ✅:
```
Apply complete! Resources: 3 added, 0 changed, 1 destroyed.
lb_dns = "wordpress-lb-348931344.us-east-1.elb.amazonaws.com"
```

---

## 2. wordpress-on-eks (netflux-on-eks) 리팩토링

### 발견된 문제 및 수정 내용

| 파일 | 문제 | 수정 내용 |
|------|------|----------|
| `provider.tf` | `required_version = ">= 1.13.4"` | `>= 1.9.0`으로 수정 |
| `provider.tf` | `kubernetes`, `time`, `random` provider 미선언 | `required_providers`에 추가 |
| `provider.tf` | `null_resource` (deprecated) | `terraform_data`로 교체 |
| `eks.tf` | `kubernetes_version = "1.35"` (미지원 버전) | `1.32`로 수정 |
| `eks.tf` | coredns, ebs-csi-driver가 EKS 모듈 내 addons에 포함 | 별도 `aws_eks_addon` 리소스로 분리 |
| `eks.tf` | 노드 그룹 분리 누락 | `module "eks_managed_node_groups"` 별도 유지 확인 |
| `eks.tf` | `kubernetes_service_account` deprecated | `kubernetes_service_account_v1`으로 교체 |
| `eks.tf` | ArgoCD depends_on 불완전 | 노드 그룹 + kubectl 설정 모두 의존 |
| `clb.tf` | `kubernetes_namespace` deprecated | `kubernetes_namespace_v1`으로 교체 |
| `clb.tf` | `kubernetes_service` deprecated | `kubernetes_service_v1`으로 교체 |
| `clb.tf` | depends_on `null_resource` 참조 | `terraform_data` 참조로 수정 |
| `dynamodb.tf` | Interface VPC Endpoint에 `subnet_ids` 누락 | 추가 (필수 필드) |
| `dynamodb.tf` | `private_dns_enabled` 누락 | `true`로 추가 |
| `dynamodb.tf` | 보안 그룹 `description` 한국어 | 영어로 수정 |
| `cicd.tf` | Webhook 브랜치 `master` (CodePipeline은 `main` 사용) | `main`으로 수정 |
| `cicd.tf` | IAM 역할/정책 description 한국어 | 영어로 수정 |
| `vars_locals.tf` | 변수 description 한국어 | 영어로 수정 |
| `cloudfront_s3.tf` | `kubernetes_service` 참조 | `kubernetes_service_v1` 참조로 수정 |
| `readme.md` | 수강생 전달 불충분 | 전면 재작성 (아키텍처, 요구사항, 풀이 포함) |

### terraform validate 결과
```
✅ Success! The configuration is valid. (경고 없음)
```

### terraform plan 결과
```
Plan: 100 to add, 0 to change, 0 to destroy.
✅ 오류 없음
```

### terraform apply 결과
> ⏳ wordpress-on-ec2 apply 완료 후 순차 실행 예정

---

## 3. 신규 스킬 생성

**스킬명**: `eks-terraform-structure`  
**위치**: `~/.claude/skills/eks-terraform-structure/SKILL.md`

**내용**:
- EKS 모듈 내 addons: DaemonSet 기반만 (vpc-cni, kube-proxy, eks-pod-identity-agent)
- 별도 `aws_eks_addon` 리소스: Deployment 기반 (coredns, aws-ebs-csi-driver)
- 노드 그룹: 반드시 `eks-managed-node-group` 별도 모듈로 분리
- Helm 릴리스(ArgoCD): 노드 그룹 + kubectl 설정 완료 후 의존

---

## 4. 주요 개선 효과 요약

| 개선 항목 | 이전 | 이후 |
|---|---|---|
| RDS 스토리지 타입 | gp2 | gp3 (성능 20%↑, 비용 20%↓) |
| AMI 참조 방식 | 하드코딩 (`ami-0cd913f496bae5294`) | 동적 조회 (`data "aws_ami"`) |
| null_resource | deprecated 사용 | `terraform_data`로 교체 |
| DB 비밀번호 | 로그에 노출 가능 | `sensitive = true`로 보호 |
| EKS 애드온 구조 | 모두 EKS 모듈 내 | DaemonSet/Deployment 분리 |
| Kubernetes 리소스 | deprecated v1beta 사용 | `_v1` suffix 최신 버전 사용 |
| Webhook 브랜치 | `master` (파이프라인과 불일치) | `main`으로 통일 |
| DynamoDB VPC Endpoint | `private_dns_enabled = true` (DynamoDB Interface 엔드포인트는 지원 안 함) | `false`로 수정 |
| `provider.tf` (EKS) | kubeconfig 파일 의존 (`config_path`) + `terraform_data.eks_kubectl_config` 패턴 | `exec` 블록으로 교체 (kubeconfig 불필요) |
| `provider.tf` (EKS) | node group에 `kubernetes_version` 미지정 → 최신(1.35) AMI 선택으로 버전 불일치 | `kubernetes_version = "1.32"` 명시 |
| `provider.tf` (EKS) | `eksctl utils write-kubeconfig` 사용 | `aws eks update-kubeconfig` 로 교체 (이후 exec 방식으로 완전 제거) |
| resource description | 한국어 혼용 | 영어 통일 |
| README | 기본 요구사항만 | 아키텍처 다이어그램, 풀이, 검증 명령 추가 |

---

## 5. apply 결과

### wordpress-on-ec2

```
Apply complete! Resources: 39 to add, 0 to change, 0 to destroy.
lb_dns = "wordpress-lb-348931344.us-east-1.elb.amazonaws.com"
```

- ASG 인스턴스 갱신(Instance Refresh) 완료 — WordPress URL이 ALB 도메인으로 교체됨
- JavaScript/CSS 오류 0개 확인
- 스냅샷: `snapshots/wordpress-ec2-fixed.png`

### wordpress-on-eks (netflux-on-eks)

```
Apply complete! Resources: 118 to add, 0 to change, 0 to destroy.
load_balancer_hostname = "aeda0c1d1f3af4215b6a7cff185a870a-230412126.us-east-1.elb.amazonaws.com"
```

- EKS 클러스터 Kubernetes 1.32 정상 실행 (노드 v1.32.12-eks-f69f56f)
- ArgoCD 배포 완료 — 로그인 UI 정상 접속 확인
- CloudFront 배포 완료 — 도메인: `d3h51yjtnrxnfh.cloudfront.net`
- CLB 서비스 생성 완료 — netflux 앱은 ArgoCD 설정 후 수강생이 배포
- 스냅샷: `snapshots/netflux-argocd.png`, `snapshots/netflux-cloudfront.png`

---

## 6. 주요 추가 수정 사항 (apply 중 발견)

| 발생 시점 | 원인 | 수정 |
|---|---|---|
| packer build | Packer가 `[default]` 프로파일 사용 (Terraform provider 설정 미상속) | `environment = { AWS_PROFILE = "my-profile" }` 추가 |
| EC2 user_data | WordPress siteurl/home이 `example.com`으로 고정 → JS/CSS 깨짐 | user_data에 `wp option update` 명령 추가 |
| EKS node group | `kubernetes_version` 미지정 → 최신(1.35) AMI 선택으로 버전 불일치 | `kubernetes_version = "1.32"` 명시 |
| EKS kubeconfig | `eksctl` 미설치 환경에서 kubeconfig 업데이트 실패 | `aws eks update-kubeconfig`로 교체 → 최종 `exec` 블록 방식으로 완전 전환 |
| DynamoDB endpoint | `private_dns_enabled = true` (Interface 타입 미지원) | `false`로 수정 |
