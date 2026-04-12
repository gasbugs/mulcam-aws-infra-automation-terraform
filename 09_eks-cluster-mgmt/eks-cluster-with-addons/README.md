# EKS 클러스터 + 다중 Addon 실습

## 실습 목표

이 실습을 통해 다음을 배울 수 있습니다:

- EKS Addon(추가 기능)이 무엇인지 이해하고 Terraform으로 관리하는 방법
- EBS CSI, EFS CSI, VPC CNI, CloudWatch 옵저버빌리티 Addon을 IRSA와 함께 설정하는 방법
- Amazon EFS(Elastic File System)를 생성하고 EKS 클러스터에 연결하는 방법
- EBS/EFS StorageClass로 PersistentVolumeClaim을 동적으로 프로비저닝하는 방법
- CloudWatch Container Insights로 컨테이너 메트릭과 로그를 수집하는 방법
- 별도의 노드 그룹 모듈(`eks-managed-node-group`)을 사용하는 방법
- **노드 없이도 활성화 가능한 Addon(DaemonSet)** 과 **노드가 있어야 하는 Addon(Deployment)** 의 차이

---

## Addon 배포 시점 분류

| 구분 | Addon | 이유 |
|------|-------|------|
| **노드 불필요** (EKS 모듈 내 `addons` 블록) | `vpc-cni`, `kube-proxy` | DaemonSet 기반, 노드 없이도 ACTIVE 전환 가능 |
| **노드 필요** (`aws_eks_addon` 리소스, `depends_on`) | `coredns`, `aws-ebs-csi-driver`, `aws-efs-csi-driver`, `amazon-cloudwatch-observability` | Deployment 기반, 파드를 스케줄할 노드가 있어야 ACTIVE 전환 |

---

## 아키텍처 개요

```
[VPC 10.0.0.0/16]
  ├── 퍼블릭 서브넷 x3
  └── 프라이빗 서브넷 x3
        ├── EKS 클러스터 (v1.34)
        │     └── 관리형 노드 그룹 (c5.large x2)
        └── EFS 마운트 타겟 x3
              └── EFS 파일시스템 (암호화)

[Addons — 노드 불필요]
  ├── vpc-cni       ── VPC 내 파드 IP 직접 할당 (IRSA 연동)
  └── kube-proxy    ── 네트워크 규칙 관리

[Addons — 노드 필요]
  ├── coredns                         ── 클러스터 내부 DNS
  ├── aws-ebs-csi-driver              ── EBS 블록 스토리지 동적 프로비저닝 (IRSA 연동)
  ├── aws-efs-csi-driver              ── EFS 파일 스토리지 동적 프로비저닝 (IRSA 연동)
  └── amazon-cloudwatch-observability ── 컨테이너 로그·메트릭·트레이스 수집 (IRSA 연동)
```

---

## 주요 리소스

| 리소스 | 설명 | 특이사항 |
|--------|------|---------|
| EKS 클러스터 (v1.34) | Kubernetes 클러스터 본체 | 퍼블릭 엔드포인트 활성화 |
| 관리형 노드 그룹 | 워커 노드 | c5.large, 최소 1 / 최대 3 |
| vpc-cni Addon | 파드에 VPC IP 주소 직접 할당 | IRSA 연동 (`AmazonEKS_CNI_Policy`) |
| aws-ebs-csi-driver | EBS 블록 스토리지 동적 프로비저닝 | IRSA 연동 (`AmazonEBSCSIDriverPolicy`) |
| aws-efs-csi-driver | EFS 파일 스토리지 동적 프로비저닝 | IRSA 연동 (`AmazonElasticFileSystemFullAccess`) |
| amazon-cloudwatch-observability | 컨테이너 Insights 에이전트 | IRSA 연동 (`CloudWatchAgentServerPolicy`, `AWSXrayWriteOnlyAccess`) |
| EFS 파일시스템 | 다중 파드에서 공유 가능한 파일 스토리지 | 암호화 활성화 |
| EFS 마운트 타겟 | 각 가용 영역에서 EFS 접근 가능하게 함 | 프라이빗 서브넷 x3 |

---

## 실습 순서

### 1단계: 초기화

```bash
cd 09_eks-cluster-mgmt/eks-cluster-with-addons
terraform init
```

### 2단계: 리소스 변경 사항 미리 보기

```bash
terraform plan
```

### 3단계: 배포 (약 20~25분 소요)

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

### 5단계: Addon 전체 상태 확인

```bash
# 설치된 Addon 목록 확인
aws eks list-addons \
  --cluster-name $(terraform output -raw cluster_name) \
  --region us-east-1 --profile my-profile

# kube-system 파드 확인 (ebs-csi, efs-csi, aws-node, coredns)
kubectl get pods -n kube-system | grep -E "ebs-csi|efs-csi|aws-node|coredns"

# CloudWatch 에이전트 파드 확인
kubectl get pods -n amazon-cloudwatch
```

### 6단계: EBS StorageClass 동적 프로비저닝 테스트

```bash
# PVC 생성 (gp2 = 기본 EBS 스토리지 클래스)
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ebs-test-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp2
  resources:
    requests:
      storage: 1Gi
EOF

# 파드를 붙여야 Bound 전환 (WaitForFirstConsumer 모드)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ebs-test-pod
spec:
  containers:
  - name: app
    image: busybox
    command: ["sleep", "300"]
    volumeMounts:
    - mountPath: "/data"
      name: ebs-vol
  volumes:
  - name: ebs-vol
    persistentVolumeClaim:
      claimName: ebs-test-pvc
EOF

# PVC Bound 및 파드 Running 확인
kubectl get pvc ebs-test-pvc
kubectl get pod ebs-test-pod

# 정리
kubectl delete pod ebs-test-pod
kubectl delete pvc ebs-test-pvc
```

### 7단계: EFS StorageClass 동적 프로비저닝 테스트

```bash
EFS_ID=$(terraform output -raw efs_file_system_id)

# EFS StorageClass 생성
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: ${EFS_ID}
  directoryPerms: "700"
EOF

# EFS PVC 생성 (ReadWriteMany — 여러 파드 동시 마운트 가능)
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-test-pvc
spec:
  accessModes: [ReadWriteMany]
  storageClassName: efs-sc
  resources:
    requests:
      storage: 1Gi
EOF

# 파드 2개를 동시에 마운트하여 EFS 공유 확인
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: efs-writer
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo hello-from-efs > /data/test.txt && sleep 300"]
    volumeMounts:
    - mountPath: "/data"
      name: efs-vol
  volumes:
  - name: efs-vol
    persistentVolumeClaim:
      claimName: efs-test-pvc
---
apiVersion: v1
kind: Pod
metadata:
  name: efs-reader
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "sleep 10 && cat /data/test.txt && sleep 300"]
    volumeMounts:
    - mountPath: "/data"
      name: efs-vol
  volumes:
  - name: efs-vol
    persistentVolumeClaim:
      claimName: efs-test-pvc
EOF

sleep 20
# efs-reader 로그에서 "hello-from-efs" 출력 확인
kubectl logs efs-reader

# 정리
kubectl delete pod efs-writer efs-reader
kubectl delete pvc efs-test-pvc
kubectl delete storageclass efs-sc
```

### 8단계: CloudWatch Container Insights 확인

```bash
# CloudWatch 에이전트 상태 확인
kubectl get pods -n amazon-cloudwatch

# CloudWatch 에이전트 로그 확인
kubectl logs -n amazon-cloudwatch \
  $(kubectl get pods -n amazon-cloudwatch -l app.kubernetes.io/name=cloudwatch-agent -o name | head -1) \
  --tail=20

# AWS 콘솔에서 확인: CloudWatch → Container Insights → 클러스터 선택
```

### 9단계: 리소스 삭제

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
| c5.large 노드 x2 | ~$0.34 |
| NAT 게이트웨이 | ~$0.045 |
| EFS 스토리지 | 사용량에 따라 과금 |

실습 종료 후 반드시 `terraform destroy`를 실행하세요.
