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

## 사전 요구사항

- AWS CLI 설정 완료 (`my-profile` 프로파일)
- `eksctl`, `kubectl`, `git` 설치
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

#### buildspec.yml 확인

`gasbugs/flask-example`에 이미 포함되어 있습니다.
없을 경우 아래 내용으로 레포 루트에 생성하세요:

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

```bash
cd flask-example
echo "# trigger" >> README.md
git add README.md
git commit -m "test: trigger CI pipeline"
git push codecommit main
```

---

## 4단계: 파이프라인 및 ArgoCD 확인

```bash
# ECR 이미지 확인
aws ecr describe-images \
  --repository-name flask-example \
  --region us-east-1 --profile my-profile \
  --query 'imageDetails[].[imageTags[0],imagePushedAt]' \
  --output table

# ArgoCD 서비스 주소 확인
kubectl get svc -n argocd argocd-server

# ArgoCD 초기 비밀번호
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# flask-app 배포 상태
kubectl get pods -n flask-app
```

---

## 5단계: 이미지 태그 업데이트 (GitOps 테스트)

```bash
cd flask-example-apps

NEW_TAG=$(aws ecr describe-images --repository-name flask-example \
  --region us-east-1 --profile my-profile \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' \
  --output text)

# deployment.yaml의 이미지 태그 수정
ECR_URL=$(terraform output -raw ecr_repository_url)
sed -i "s|image:.*|image: $ECR_URL:$NEW_TAG|g" deployment.yaml

git add .
git commit -m "chore: update image to $NEW_TAG"
git push codecommit main

# ArgoCD 자동 동기화 확인
kubectl get pods -n flask-app -w
```

---

## 리소스 삭제

```bash
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
- EKS + ArgoCD + CodePipeline 동시 실행 시 비용 주의
