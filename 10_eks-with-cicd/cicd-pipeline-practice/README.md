# cicd-pipeline-practice — Flask CI/CD 파이프라인 실습 (직접 구성 버전)

## 학습 목표

`cicd-pipeline`(완성 버전)을 참고하여 아래 리소스를 직접 작성하는 실습입니다:

- CodeCommit 저장소 생성 (`flask-example`, `flask-example-apps`)
- CodePipeline Source 스테이지를 CodeCommit 저장소로 구성
- EventBridge로 CodeCommit push → 파이프라인 자동 트리거 설정
- ArgoCD SSH 인증 리소스 작성 (IAM 유저 + SSH 키 + Kubernetes Secret)

## 실습 구조

이 디렉토리의 파일들은 `cicd-pipeline`과 동일하게 동작합니다.
변수명만 일부 다르게 구성되어 있습니다:
- `var.app_name` (기본값: `flask-example`) — ECR 저장소명 및 파이프라인 이름에 사용

## 전체 아키텍처 흐름

```
flask-example(앱 소스)
    → CodeCommit push
    → EventBridge 감지
    → CodePipeline 실행
    → CodeBuild: Docker 이미지 빌드 + ECR push
    
flask-example-apps(K8s 매니페스트)
    → CodeCommit push
    → ArgoCD 감지 (SSH로 저장소 폴링)
    → EKS 클러스터에 자동 배포
```

## 사전 요구사항

- AWS CLI 설정 완료 (`my-profile` 프로파일)
- `kubectl`, `git` 설치
- Terraform >= 1.13.4

---

## 1단계: Terraform 배포

```bash
cd 10_eks-with-cicd/cicd-pipeline-practice
terraform init
terraform apply
```

> ⏱ 소요 시간: 약 20~30분

배포 완료 후 출력값 확인:
```bash
terraform output
# codecommit_flask_example_url      = "https://git-codecommit.us-east-1.amazonaws.com/v1/repos/flask-example"
# codecommit_flask_example_apps_url = "https://git-codecommit.us-east-1.amazonaws.com/v1/repos/flask-example-apps"
# ecr_repository_url                = "<계정ID>.dkr.ecr.us-east-1.amazonaws.com/flask-example"
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
  | grep ssh-rsa | sed 's/^#.* //')

# ArgoCD known hosts ConfigMap에 추가
EXISTING=$(kubectl get configmap argocd-ssh-known-hosts-cm -n argocd \
  -o jsonpath='{.data.ssh_known_hosts}')

NEW_HOSTS="${EXISTING}
${CODECOMMIT_KEY}"

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
```

`buildspec.yml`이 없으면 아래 내용으로 레포 루트에 생성하세요:

```yaml
version: 0.2
phases:
  pre_build:
    commands:
      - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $ECR_REPO_URI
      - IMAGE_TAG=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c1-7)
  build:
    commands:
      - docker build -t $ECR_REPO_URI:$IMAGE_TAG .
      - docker tag $ECR_REPO_URI:$IMAGE_TAG $ECR_REPO_URI:latest
  post_build:
    commands:
      - docker push $ECR_REPO_URI:$IMAGE_TAG
      - docker push $ECR_REPO_URI:latest
      - echo Build complete. Image $ECR_REPO_URI:$IMAGE_TAG
```

```bash
# buildspec.yml 추가 후 push (없는 경우)
git add buildspec.yml
git commit -m "ci: add buildspec.yml for CodeBuild"

git remote add codecommit $FLASK_EXAMPLE_URL
git push codecommit main
cd ..
```

> push 즉시 EventBridge가 CodePipeline을 자동 트리거합니다.

### flask-example-apps (K8s 매니페스트) 복제 및 push

```bash
FLASK_APPS_URL=$(terraform output -raw codecommit_flask_example_apps_url)
ECR_URL=$(terraform output -raw ecr_repository_url)

git clone https://github.com/gasbugs/flask-example-apps
cd flask-example-apps
```

`flask-example-deploy/deployment.yaml`의 이미지를 ECR URL로 업데이트합니다:

```bash
# deployment.yaml의 이미지를 ECR 주소로 교체
sed -i "s|image:.*|image: $ECR_URL:latest|g" flask-example-deploy/deployment.yaml

git add flask-example-deploy/deployment.yaml
git commit -m "ci: update image to ECR URL"

git remote add codecommit $FLASK_APPS_URL
git push codecommit main
cd ..
```

---

## 5단계: 파이프라인 및 배포 확인

### CodePipeline 상태 확인

```bash
# 파이프라인 이름 확인 (terraform output이 있는 디렉토리에서)
PIPELINE_NAME=$(aws codepipeline list-pipelines --region us-east-1 --profile my-profile \
  --query 'pipelines[?contains(name, `flask-example`)].name' --output text)

aws codepipeline get-pipeline-state --name $PIPELINE_NAME \
  --region us-east-1 --profile my-profile \
  --query 'stageStates[*].[stageName,latestExecution.status]' --output table
# Source | Succeeded
# Build  | Succeeded
```

### ECR 이미지 확인

```bash
aws ecr describe-images --repository-name flask-example \
  --region us-east-1 --profile my-profile \
  --query 'imageDetails[].[imageTags[0],imagePushedAt]' --output table
```

### ArgoCD Application 상태 확인

```bash
kubectl get application flask-app -n argocd
# STATUS: Synced / HEALTH: Healthy

# ArgoCD 초기 관리자 비밀번호
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### Flask 파드 실행 확인

```bash
kubectl get pods -n flask-app
# NAME                     READY   STATUS    RESTARTS   AGE
# flask-xxxxxxxxx-xxxxx   1/1     Running   0          xxs   ← 5개 파드 Running
```

---

## 6단계: GitOps 테스트 (이미지 태그 업데이트)

코드 변경 → 자동 빌드 → 이미지 태그 업데이트 → ArgoCD 자동 배포 흐름을 검증합니다.

### 파이프라인 재트리거

```bash
cd flask-example
echo "# update $(date)" >> README.md
git add README.md
git commit -m "test: trigger CI pipeline"
git push codecommit main
```

> push 즉시 EventBridge가 파이프라인을 다시 실행합니다. 빌드 완료 후 ECR에 새 이미지 태그 생성.

### manifest 이미지 태그 업데이트

빌드 완료 후 최신 이미지 태그를 `flask-example-apps`에 반영합니다:

```bash
cd flask-example-apps

# 최신 이미지 태그 가져오기 (커밋 해시 7자리)
NEW_TAG=$(aws ecr describe-images --repository-name flask-example \
  --region us-east-1 --profile my-profile \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' \
  --output text)

ECR_URL=$(terraform -chdir=../cicd-pipeline-practice output -raw ecr_repository_url)

# deployment.yaml 이미지 태그 수정
sed -i "s|image:.*|image: $ECR_URL:$NEW_TAG|g" flask-example-deploy/deployment.yaml

git add flask-example-deploy/deployment.yaml
git commit -m "chore: update image to $NEW_TAG"
git push codecommit main
```

### ArgoCD 동기화 확인 (폴링 주기: 3분)

```bash
kubectl get pods -n flask-app -w
# 이전 파드가 Terminating되고 새 파드가 ContainerCreating → Running으로 전환
```

> 즉시 반영하려면 수동 refresh를 실행하세요:
> ```bash
> kubectl annotate application flask-app -n argocd \
>   argocd.argoproj.io/refresh="hard" --overwrite
> ```

---

## 리소스 삭제

```bash
# ArgoCD Application 먼저 삭제 (flask-app 네임스페이스 정리)
kubectl delete application flask-app -n argocd

terraform destroy -auto-approve
```

---

## 참고: cicd-pipeline(완성본)과의 차이점

| 항목 | cicd-pipeline | cicd-pipeline-practice |
|------|--------------|----------------------|
| 변수 | 고정값 (`ecr_repo_name = "flask-example"`) | `var.app_name`으로 파라미터화 |
| 태그 | BlackCompany 팀 태그 | cloudsecuritylab 팀 태그 |
| 구조 | 동일 | 동일 |

## 주의사항

- **테스트 완료 즉시 `terraform destroy` 실행 필수** (비용 절감)
- CodeCommit HTTPS 인증은 `credential.helper` 설정이 없으면 실패함
- ArgoCD SSH known hosts 설정(3단계)을 빠뜨리면 배포가 진행되지 않음
- `flask-example-apps`의 매니페스트는 `flask-example-deploy/` 디렉토리에 위치
- EKS + ArgoCD + CodePipeline 동시 실행 시 비용 주의
