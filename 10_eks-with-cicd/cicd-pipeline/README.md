# cicd-pipeline — Flask CI/CD 파이프라인 (CodeCommit + CodeBuild + ArgoCD)

## 학습 목표

- AWS CodeCommit으로 Git 저장소를 관리하는 방법 이해
- CodePipeline + CodeBuild로 Flask Python 앱을 자동 빌드·ECR 푸시하는 파이프라인 구성
- ArgoCD가 CodeCommit에서 K8s 매니페스트를 읽어 EKS에 자동 배포하는 GitOps 플로우 구현
- EventBridge를 이용한 이벤트 기반 파이프라인 트리거 (polling 없이 즉시 실행)

## 아키텍처

```
GitHub(flask-example)      →  CodeCommit(flask-example)
                                       │
                                EventBridge 트리거
                                       │
                                CodePipeline(Source)
                                       │
                                CodeBuild(빌드·ECR 푸시)
                                       │
                                ECR(Docker 이미지 저장)

GitHub(flask-example-apps) →  CodeCommit(flask-example-apps)
                                       │
                                ArgoCD(자동 동기화)
                                       │
                                EKS(flask-app 네임스페이스)
```

## 사전 요구사항

- AWS CLI 설정 완료 (`my-profile` 프로파일)
- `eksctl`, `kubectl`, `git` 설치
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

## 2단계: CodeCommit에 소스 코드 복제

### git credential helper 설정 (최초 1회)
```bash
git config --global credential.helper '!aws --profile my-profile codecommit credential-helper $@'
git config --global credential.UseHttpPath true
```

### flask-example (앱 소스) 복제 및 push

```bash
FLASK_EXAMPLE_URL=$(terraform output -raw codecommit_flask_example_url)

git clone https://github.com/gasbugs/flask-example
cd flask-example
git remote add codecommit $FLASK_EXAMPLE_URL
git push codecommit main
cd ..
```

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

git clone https://github.com/gasbugs/flask-example-apps
cd flask-example-apps
git remote add codecommit $FLASK_APPS_URL
git push codecommit main
cd ..
```

---

## 3단계: 파이프라인 실행 트리거

`flask-example`에 코드를 push하면 EventBridge가 감지하여 CodePipeline이 자동 실행됩니다.

```bash
cd flask-example
echo "# pipeline trigger test" >> README.md
git add README.md
git commit -m "test: trigger CI pipeline"
git push codecommit main
```

---

## 4단계: 파이프라인 실행 확인

```bash
# CodePipeline 최근 실행 상태 확인 (콘솔에서 파이프라인 이름 확인 후)
aws codepipeline list-pipeline-executions \
  --pipeline-name <파이프라인-이름> \
  --region us-east-1 --profile my-profile \
  --query 'pipelineExecutionSummaries[0].{status:status,startTime:startTime}'

# ECR에 이미지가 push됐는지 확인
aws ecr describe-images \
  --repository-name flask-example \
  --region us-east-1 --profile my-profile \
  --query 'imageDetails[].[imageTags[0],imagePushedAt]' \
  --output table
```

---

## 5단계: ArgoCD 확인

```bash
# ArgoCD 서비스 외부 주소 확인
kubectl get svc -n argocd argocd-server

# ArgoCD 초기 비밀번호 확인
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# ArgoCD Application 동기화 상태 확인
kubectl get applications -n argocd

# flask-app 파드 확인
kubectl get pods -n flask-app
kubectl get svc -n flask-app
```

ArgoCD UI 접속: `http://<EXTERNAL-IP>` (admin / 위에서 확인한 비밀번호)

---

## 6단계: GitOps 전체 플로우 테스트

파이프라인 빌드 완료 후 `flask-example-apps`의 이미지 태그를 업데이트하면
ArgoCD가 자동으로 EKS에 새 버전을 배포합니다:

```bash
cd flask-example-apps

# ECR에서 새 이미지 태그 확인
NEW_TAG=$(aws ecr describe-images --repository-name flask-example \
  --region us-east-1 --profile my-profile \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' \
  --output text)
echo "New image tag: $NEW_TAG"

# deployment.yaml의 이미지 태그를 새 태그로 수정 후
ECR_URL=$(cd ../cicd-pipeline && terraform output -raw ecr_repository_url)
sed -i "s|image:.*|image: $ECR_URL:$NEW_TAG|g" deployment.yaml  # 또는 직접 편집

git add .
git commit -m "chore: update flask-app image to $NEW_TAG"
git push codecommit main

# ArgoCD 자동 동기화 확인 (약 3분 이내)
kubectl get pods -n flask-app -w
```

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
| `kubernetes_secret.argocd_repo_flask_example_apps` | ArgoCD 저장소 인증 시크릿 |
| `kubernetes_manifest.argocd_application` | ArgoCD Application (flask-app) |

## 주의사항

- EKS + ArgoCD + CodePipeline 동시 실행 시 비용 주의 (c5.large × 2 ≈ 시간당 $0.34)
- **테스트 완료 즉시 `terraform destroy` 실행 필수**
- CodeCommit HTTPS 인증은 `credential.helper` 설정이 없으면 실패할 수 있음
- ArgoCD가 CodeCommit SSH URL을 처음 연결할 때 known_hosts 검증 없이 진행 (insecure 모드)
