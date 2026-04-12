# cicd-pipeline — Flask CI/CD 파이프라인 (CodeCommit + CodeBuild + ArgoCD)

## 학습 목표

- AWS CodeCommit으로 Git 저장소를 관리하는 방법 이해
- CodePipeline + CodeBuild로 Flask Python 앱을 자동 빌드·ECR 푸시하는 파이프라인 구성
- ArgoCD가 CodeCommit에서 K8s 매니페스트를 읽어 EKS에 자동 배포하는 GitOps 플로우 구현
- EventBridge를 이용한 이벤트 기반 파이프라인 트리거 (polling 없이 즉시 실행)

## 전체 아키텍처 흐름

```
flask-example(앱 소스)
    → CodeCommit push
    → EventBridge 감지
    → CodePipeline(Source → Build)
    → CodeBuild: Docker 이미지 빌드 + ECR push

flask-example-apps(K8s 매니페스트)
    → CodeCommit push
    → ArgoCD 감지 (SSH로 저장소 폴링)
    → EKS(flask-app 네임스페이스)에 자동 배포
```

## 사전 요구사항

- AWS CLI 설정 완료 (`my-profile` 프로파일)
- `kubectl`, `git` 설치
- Terraform >= 1.13.4

---

## 1단계: Terraform 배포

```bash
cd 10_eks-with-cicd/cicd-pipeline
terraform init
terraform apply
```

> ⏱ 소요 시간: 약 20~30분 (EKS 클러스터 + ArgoCD 설치 포함)

배포 완료 후 출력값 확인:
```bash
terraform output
# codecommit_flask_example_url      = "https://git-codecommit.us-east-1.amazonaws.com/v1/repos/flask-example"
# codecommit_flask_example_apps_url = "https://git-codecommit.us-east-1.amazonaws.com/v1/repos/flask-example-apps"
# ecr_repository_url                = "445567110488.dkr.ecr.us-east-1.amazonaws.com/flask-example"
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
# kubeconfig 업데이트 (클러스터 이름은 terraform output에서 확인)
CLUSTER_NAME=$(aws eks list-clusters --region us-east-1 --profile my-profile \
  --query 'clusters[?contains(@, `education-eks`)]' --output text)
aws eks update-kubeconfig --region us-east-1 --profile my-profile --name $CLUSTER_NAME

# CodeCommit SSH 호스트 키 가져오기
CODECOMMIT_KEY=$(ssh-keyscan git-codecommit.us-east-1.amazonaws.com 2>/dev/null \
  | grep ssh-rsa | head -1 | awk '{print $2, $3}')
CODECOMMIT_ENTRY="git-codecommit.us-east-1.amazonaws.com $CODECOMMIT_KEY"

# ArgoCD known hosts ConfigMap에 추가
EXISTING=$(kubectl get configmap argocd-ssh-known-hosts-cm -n argocd \
  -o jsonpath='{.data.ssh_known_hosts}')

NEW_HOSTS="${EXISTING}
${CODECOMMIT_ENTRY}"

kubectl patch configmap argocd-ssh-known-hosts-cm -n argocd \
  --type merge \
  -p "{\"data\":{\"ssh_known_hosts\":$(echo "$NEW_HOSTS" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}}"

# repo-server 재시작하여 변경 반영
kubectl rollout restart deployment argocd-repo-server -n argocd
kubectl rollout status deployment argocd-repo-server -n argocd --timeout=90s
```

---

## 4단계: CodeCommit에 소스 코드 복제 및 push

### flask-example (앱 소스) 복제 및 push

```bash
FLASK_EXAMPLE_URL=$(terraform output -raw codecommit_flask_example_url)

git clone https://github.com/gasbugs/flask-example
cd flask-example
git remote add codecommit $FLASK_EXAMPLE_URL
git push codecommit main
cd ..
```

> push 즉시 EventBridge가 CodePipeline을 자동 트리거합니다.

#### buildspec.yml (flask-example 레포 루트에 반드시 있어야 함)

CodeBuild가 이 파일을 읽어 Flask Docker 이미지를 빌드합니다.
`gasbugs/flask-example`에 이미 포함되어 있습니다. 없을 경우 아래 내용으로 생성하세요:

```yaml
version: 0.2
phases:
  pre_build:
    commands:
      - echo Logging in to Amazon ECR...
      - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $ECR_REPO_URI
      - IMAGE_TAG=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c1-7)
      - echo "Image tag is $IMAGE_TAG"
  build:
    commands:
      - echo Building Flask Docker image...
      - docker build -t $ECR_REPO_URI:$IMAGE_TAG .
      - docker tag $ECR_REPO_URI:$IMAGE_TAG $ECR_REPO_URI:latest
  post_build:
    commands:
      - echo Pushing image to ECR...
      - docker push $ECR_REPO_URI:$IMAGE_TAG
      - docker push $ECR_REPO_URI:latest
      - echo Build complete. Image $ECR_REPO_URI:$IMAGE_TAG
```

### flask-example-apps (K8s 매니페스트) 복제 및 push

```bash
FLASK_APPS_URL=$(terraform output -raw codecommit_flask_example_apps_url)
ECR_URL=$(terraform output -raw ecr_repository_url)

git clone https://github.com/gasbugs/flask-example-apps
cd flask-example-apps

# flask-example-deploy/deployment.yaml의 이미지를 ECR 주소로 교체
sed -i "s|image:.*|image: $ECR_URL:latest|g" flask-example-deploy/deployment.yaml

git add flask-example-deploy/deployment.yaml
git commit -m "ci: update image to ECR URL"

git remote add codecommit $FLASK_APPS_URL
git push codecommit main
cd ..
```

> **참고:** K8s 매니페스트는 `flask-example-deploy/` 디렉토리 안에 있습니다.
> ArgoCD Application은 `path = "flask-example-deploy"`로 이 디렉토리를 바라봅니다.

---

## 5단계: 파이프라인 실행 확인

```bash
# 파이프라인 이름 확인
PIPELINE_NAME=$(aws codepipeline list-pipelines --region us-east-1 --profile my-profile \
  --query 'pipelines[?contains(name, `flask-example`)].name' --output text)

aws codepipeline get-pipeline-state --name $PIPELINE_NAME \
  --region us-east-1 --profile my-profile \
  --query 'stageStates[*].[stageName,latestExecution.status]' --output table
# Source | Succeeded
# Build  | Succeeded

# ECR에 이미지가 push됐는지 확인
aws ecr describe-images \
  --repository-name flask-example \
  --region us-east-1 --profile my-profile \
  --query 'imageDetails[].[imageTags[0],imagePushedAt]' \
  --output table
```

---

## 6단계: ArgoCD 및 배포 확인

```bash
# ArgoCD Application 동기화 상태 확인
kubectl get application flask-app -n argocd
# STATUS: Synced / HEALTH: Healthy

# ArgoCD 초기 비밀번호 확인
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# flask-app 파드 확인 (5개 Running 기대)
kubectl get pods -n flask-app
kubectl get svc -n flask-app
```

---

## 7단계: GitOps 전체 플로우 테스트

파이프라인 빌드 완료 후 `flask-example-apps`의 이미지 태그를 업데이트하면
ArgoCD가 자동으로 EKS에 새 버전을 배포합니다:

```bash
# 1. 코드 변경으로 파이프라인 재트리거
cd flask-example
echo "# update $(date)" >> README.md
git add README.md
git commit -m "test: trigger CI pipeline"
git push codecommit main

# 2. 빌드 완료 후 ECR에서 새 이미지 태그 확인
cd ../flask-example-apps
NEW_TAG=$(aws ecr describe-images --repository-name flask-example \
  --region us-east-1 --profile my-profile \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' \
  --output text)
echo "New image tag: $NEW_TAG"

# 3. deployment.yaml 이미지 태그 업데이트
ECR_URL=$(cd ../cicd-pipeline && terraform output -raw ecr_repository_url)
sed -i "s|image:.*|image: $ECR_URL:$NEW_TAG|g" flask-example-deploy/deployment.yaml

git add flask-example-deploy/deployment.yaml
git commit -m "chore: update flask-app image to $NEW_TAG"
git push codecommit main

# 4. ArgoCD 동기화 확인 (폴링 주기: 3분)
kubectl get pods -n flask-app -w
```

> ArgoCD는 기본 3분 주기로 CodeCommit을 폴링합니다.
> 즉시 반영하려면 수동 refresh를 실행하세요:
> ```bash
> kubectl annotate application flask-app -n argocd \
>   argocd.argoproj.io/refresh="hard" --overwrite
> ```

---

## 리소스 삭제

```bash
# ArgoCD Application 먼저 삭제 (EKS 리소스 정리)
kubectl delete application flask-app -n argocd

# Terraform 전체 삭제
terraform destroy -auto-approve
```

---

## 구성 리소스 요약

| 리소스 | 역할 |
|--------|------|
| `aws_codecommit_repository.flask_example` | Flask 앱 소스 코드 저장소 |
| `aws_codecommit_repository.flask_example_apps` | ArgoCD K8s 매니페스트 저장소 |
| `aws_codepipeline.this` | 소스 → 빌드 자동화 파이프라인 |
| `aws_codebuild_project.this_ci` | Docker 이미지 빌드 및 ECR 푸시 |
| `aws_cloudwatch_event_rule.codecommit_trigger` | CodeCommit push → 파이프라인 트리거 |
| `aws_ecr_repository.ecr_repo` | Flask 앱 Docker 이미지 저장소 |
| `helm_release.argocd` | EKS에 ArgoCD 설치 |
| `tls_private_key.argocd_codecommit` | ArgoCD↔CodeCommit SSH 인증 키 |
| `aws_iam_user.argocd` | ArgoCD 전용 CodeCommit 읽기 권한 IAM 유저 |
| `kubernetes_secret_v1.argocd_repo_flask_example_apps` | ArgoCD 저장소 인증 시크릿 |
| `kubectl_manifest.argocd_application` | ArgoCD Application (flask-app) |

## 주의사항

- EKS + ArgoCD + CodePipeline 동시 실행 시 비용 주의 (c5.large × 2 ≈ 시간당 $0.34)
- **테스트 완료 즉시 `terraform destroy` 실행 필수**
- CodeCommit HTTPS 인증은 `credential.helper` 설정이 없으면 실패함
- ArgoCD SSH known hosts 설정(3단계)을 빠뜨리면 배포가 진행되지 않음
- `flask-example-apps`의 매니페스트는 `flask-example-deploy/` 디렉토리에 위치
