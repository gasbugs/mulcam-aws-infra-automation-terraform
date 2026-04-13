# cicd-pipeline-javaspring — Java Spring Boot CI/CD 파이프라인

Java Spring Boot 앱을 Docker 멀티 스테이지 빌드로 컨테이너화하고,
CodePipeline → ECR → ArgoCD → EKS 흐름으로 자동 배포하는 파이프라인입니다.

## 전체 아키텍처 흐름

```
[소스]  GitHub gasbugs/javaspring
           ↓ (최초 1회 복제)
[CI]    CodeCommit(javaspring)
           ↓ push → EventBridge 감지
        CodePipeline → CodeBuild
           ↓ Docker 멀티 스테이지 빌드 (Maven 컴파일 + 테스트 + JAR)
        ECR(javaspring 이미지 저장)

[GitOps] GitHub gasbugs/javaspring-apps
           ↓ (최초 1회 복제 + 이미지 태그 업데이트)
        CodeCommit(javaspring-apps)
           ↓ ArgoCD 감지 (SSH 폴링)
        EKS → javaspring-app 네임스페이스에 자동 배포
```

## Flask vs Java Spring 차이점

| 항목 | cicd-pipeline (Flask) | cicd-pipeline-javaspring (Java Spring) |
|------|----------------------|----------------------------------------|
| 언어 | Python | Java 17 |
| 빌드 | docker build 단순 빌드 | Maven 컴파일 → JAR → 멀티 스테이지 빌드 |
| 빌드 시간 | ~2분 | ~5~10분 (Maven 의존성 다운로드 포함) |
| 빌드 타임아웃 | 10분 | 20분 |
| 소스 저장소 | flask-example | javaspring |
| 매니페스트 저장소 | flask-example-apps | javaspring-apps |
| 배포 네임스페이스 | flask-app | javaspring-app |

## 사전 요구사항

- AWS CLI 설정 완료 (`my-profile` 프로파일)
- `kubectl`, `git` 설치
- Terraform >= 1.13.4

---

## 1단계: Terraform 배포

```bash
cd 10_eks-with-cicd/cicd-pipeline-javaspring
terraform init
terraform apply
```

> ⏱ 소요 시간: 약 20~30분 (EKS 클러스터 + ArgoCD 설치 포함)

배포 완료 후 출력값 확인:
```bash
terraform output
# codecommit_javaspring_url      = "https://git-codecommit.us-east-1.amazonaws.com/v1/repos/javaspring"
# codecommit_javaspring_apps_url = "https://git-codecommit.us-east-1.amazonaws.com/v1/repos/javaspring-apps"
# ecr_repository_url             = "<계정ID>.dkr.ecr.us-east-1.amazonaws.com/javaspring"
```

---

## 2단계: git credential helper 설정 (최초 1회)

CodeCommit HTTPS 인증을 위해 자격증명 헬퍼를 설정합니다:

```bash
git config --global credential.helper '!aws --profile my-profile codecommit credential-helper $@'
git config --global credential.UseHttpPath true
```

---

## 3단계: ArgoCD SSH known hosts 설정

ArgoCD가 CodeCommit SSH 서버를 신뢰하도록 호스트 키를 등록합니다.
이 단계를 건너뛰면 ArgoCD가 `knownhosts: key is unknown` 오류로 저장소를 읽지 못합니다.

```bash
# kubeconfig 업데이트
CLUSTER_NAME=$(aws eks list-clusters --region us-east-1 --profile my-profile \
  --query 'clusters[?contains(@, `education-eks`)]' --output text)
aws eks update-kubeconfig --region us-east-1 --profile my-profile --name $CLUSTER_NAME

# CodeCommit SSH 호스트 키 등록
CODECOMMIT_KEY=$(ssh-keyscan git-codecommit.us-east-1.amazonaws.com 2>/dev/null \
  | grep ssh-rsa | head -1 | awk '{print $2, $3}')
CODECOMMIT_ENTRY="git-codecommit.us-east-1.amazonaws.com $CODECOMMIT_KEY"

EXISTING=$(kubectl get configmap argocd-ssh-known-hosts-cm -n argocd \
  -o jsonpath='{.data.ssh_known_hosts}')
NEW_HOSTS="${EXISTING}
${CODECOMMIT_ENTRY}"

kubectl patch configmap argocd-ssh-known-hosts-cm -n argocd \
  --type merge \
  -p "{\"data\":{\"ssh_known_hosts\":$(echo "$NEW_HOSTS" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}}"

kubectl rollout restart deployment argocd-repo-server -n argocd
kubectl rollout status deployment argocd-repo-server -n argocd --timeout=90s
```

---

## 4단계: CodeCommit에 소스 코드 복제 및 push

### javaspring (앱 소스) 복제 및 push

```bash
JAVASPRING_URL=$(terraform output -raw codecommit_javaspring_url)

git clone https://github.com/gasbugs/javaspring
cd javaspring
git remote add codecommit $JAVASPRING_URL
git push codecommit main
cd ..
```

> push 즉시 EventBridge가 CodePipeline을 자동 트리거합니다.
> Java Spring Boot는 Maven 컴파일을 포함하므로 빌드에 5~10분 소요됩니다.

### javaspring-apps (K8s 매니페스트) 복제 및 push

```bash
JAVASPRING_APPS_URL=$(terraform output -raw codecommit_javaspring_apps_url)
ECR_URL=$(terraform output -raw ecr_repository_url)

git clone https://github.com/gasbugs/javaspring-apps
cd javaspring-apps

# deployment.yaml의 이미지 플레이스홀더를 ECR 주소로 교체
sed -i "s|image:.*|image: $ECR_URL:latest|g" deployment.yaml

git add deployment.yaml
git commit -m "ci: update image to ECR URL"
git remote add codecommit $JAVASPRING_APPS_URL
git push codecommit main
cd ..
```

---

## 5단계: 파이프라인 실행 확인

```bash
# 파이프라인 상태 확인
PIPELINE_NAME=$(aws codepipeline list-pipelines --region us-east-1 --profile my-profile \
  --query 'pipelines[?contains(name, `javaspring`)].name' --output text)

aws codepipeline get-pipeline-state --name $PIPELINE_NAME \
  --region us-east-1 --profile my-profile \
  --query 'stageStates[*].[stageName,latestExecution.status]' --output table
# Source | Succeeded
# Build  | Succeeded  (5~10분 소요)

# ECR 이미지 확인
aws ecr describe-images --repository-name javaspring \
  --region us-east-1 --profile my-profile \
  --query 'imageDetails[].[imageTags[0],imagePushedAt]' --output table
```

---

## 6단계: ArgoCD 및 배포 확인

```bash
# ArgoCD Application 상태 확인
kubectl get application javaspring-app -n argocd
# STATUS: Synced / HEALTH: Healthy

# ArgoCD 초기 비밀번호
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# 배포된 파드 확인
kubectl get pods -n javaspring-app
kubectl get svc -n javaspring-app
```

---

## 7단계: GitOps 테스트 (이미지 태그 업데이트)

코드 변경 → 자동 빌드 → 이미지 태그 업데이트 → ArgoCD 자동 배포 흐름을 검증합니다.

```bash
# 1. 코드 변경으로 파이프라인 재트리거
cd javaspring
echo "// update $(date)" >> src/main/java/com/example/App.java
git add .
git commit -m "test: trigger CI pipeline"
git push codecommit main

# 2. 빌드 완료 후 최신 이미지 태그 확인
cd ../javaspring-apps
NEW_TAG=$(aws ecr describe-images --repository-name javaspring \
  --region us-east-1 --profile my-profile \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' \
  --output text)
echo "New image tag: $NEW_TAG"

# 3. deployment.yaml 이미지 태그 업데이트
ECR_URL=$(cd ../cicd-pipeline-javaspring && terraform output -raw ecr_repository_url)
sed -i "s|image:.*|image: $ECR_URL:$NEW_TAG|g" deployment.yaml

git add deployment.yaml
git commit -m "chore: update javaspring image to $NEW_TAG"
git push codecommit main

# 4. ArgoCD 동기화 확인 (폴링 주기: 3분)
kubectl get pods -n javaspring-app -w
```

> 즉시 반영하려면:
> ```bash
> kubectl annotate application javaspring-app -n argocd \
>   argocd.argoproj.io/refresh="hard" --overwrite
> ```

---

## 리소스 삭제

```bash
kubectl delete application javaspring-app -n argocd
terraform destroy -auto-approve
```

---

## buildspec.yml 구조

`javaspring` 레포 루트의 `buildspec.yml`이 CodeBuild 빌드 명세입니다:

```yaml
version: 0.2
phases:
  pre_build:
    commands:
      - aws ecr get-login-password ... | docker login ...
      - IMAGE_TAG=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c1-7)
  build:
    commands:
      # Dockerfile의 멀티 스테이지 빌드 실행
      # 1단계(maven): Maven 컴파일 + 단위 테스트 + JAR 생성
      # 2단계(jre):   JAR만 복사하여 경량 실행 이미지 생성
      - docker build -t $ECR_REPO_URI:$IMAGE_TAG .
  post_build:
    commands:
      - docker push $ECR_REPO_URI:$IMAGE_TAG
      - docker push $ECR_REPO_URI:latest
```

## 주의사항

- **테스트 완료 즉시 `terraform destroy` 실행 필수** (비용 절감)
- Java 멀티 스테이지 빌드는 Maven 의존성 다운로드로 첫 빌드가 5~10분 소요됨
- CodeBuild `build_timeout = 20`으로 Flask(10분)보다 두 배 설정
- ArgoCD SSH known hosts 설정(3단계)을 빠뜨리면 배포가 진행되지 않음
