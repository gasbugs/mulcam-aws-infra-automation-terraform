# cicd-pipeline-javaspring — Java Spring Boot CI/CD 파이프라인

Java Spring Boot 앱을 Docker 멀티 스테이지 빌드로 컨테이너화하고,
CodePipeline → ECR → ArgoCD → EKS 흐름으로 자동 배포하는 파이프라인입니다.

## 전체 아키텍처 흐름

```
[소스]  GitHub gasbugs/javaspring
           ↓ (최초 1회 복제)
[CI]    CodeCommit(javaspring)
           ↓ push → EventBridge 감지 (즉시)
        CodePipeline → CodeBuild
           ↓ Docker 멀티 스테이지 빌드 (Maven 컴파일 + 테스트 + JAR)
        ECR(javaspring 이미지 저장)
           ↓ update_apps.sh가 deployment.yaml 이미지 태그 자동 업데이트

[GitOps] CodeCommit(javaspring-apps)
           ↓ ArgoCD가 변경 감지 (SSH 폴링, 약 3분)
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

> EKS 클러스터, CodePipeline, ArgoCD 등 모든 인프라를 한 번에 생성합니다.

```bash
# 이 프로젝트 디렉터리로 이동
cd 10_eks-with-cicd/cicd-pipeline-javaspring

# Terraform 초기화 — 필요한 프로바이더(AWS, Kubernetes 등) 플러그인 다운로드
terraform init

# 인프라 생성 — 약 20~30분 소요 (EKS 클러스터 생성이 대부분을 차지)
terraform apply
```

> ⏱ 소요 시간: 약 20~30분 (EKS 클러스터 + ArgoCD 설치 포함)

배포 완료 후 출력값 확인:
```bash
# 생성된 리소스의 접속 URL 확인
terraform output
```

**기대 출력:**
```
argocd_server_service          = "kubectl get svc -n argocd argocd-server"
codecommit_javaspring_apps_url = "https://git-codecommit.us-east-1.amazonaws.com/v1/repos/javaspring-apps"
codecommit_javaspring_url      = "https://git-codecommit.us-east-1.amazonaws.com/v1/repos/javaspring"
ecr_repository_url             = "123456789012.dkr.ecr.us-east-1.amazonaws.com/javaspring"
```

---

## 2단계: 스크립트 한 번에 실행 (권장)

> 3~4단계를 자동으로 처리하는 스크립트입니다.
> git credential 설정, ArgoCD SSH 등록, CodeCommit push까지 한 번에 수행합니다.

```bash
# push_to_codecommit.sh 실행 (terraform apply 완료 후 실행)
bash push_to_codecommit.sh
```

**기대 출력:**
```
[19:46:09] terraform output 읽는 중...
[19:46:10]   javaspring      : https://git-codecommit.us-east-1.amazonaws.com/v1/repos/javaspring
[19:46:10]   javaspring-apps : https://git-codecommit.us-east-1.amazonaws.com/v1/repos/javaspring-apps
[19:46:10]   ECR             : 123456789012.dkr.ecr.us-east-1.amazonaws.com/javaspring
[19:46:10] git credential helper 설정 중...
[19:46:13]   클러스터: education-eks-xxxxxxxx
[19:46:13] ArgoCD SSH known hosts에 CodeCommit 호스트 키 등록 중...
...
[19:46:34]   ArgoCD SSH known hosts 등록 완료
[19:46:34] javaspring 앱 소스 클론 및 CodeCommit push 중...
...
[19:46:38]   javaspring push 완료 — CodePipeline이 자동 트리거됩니다 (빌드 5~10분 소요)
[19:46:38] javaspring-apps 매니페스트 클론 및 이미지 주소 업데이트 중...
...
[19:46:42]   javaspring-apps push 완료
============================================================
  CodeCommit push 완료
============================================================
```

> 스크립트를 사용하지 않으려면 아래 2-1 ~ 2-3 단계를 수동으로 진행하세요.

---

## 2-1단계: git credential helper 설정 (수동, 최초 1회)

> AWS CodeCommit은 일반 GitHub 계정으로 로그인할 수 없습니다.
> AWS CLI를 git 인증 도구로 사용하도록 설정해야 합니다.

```bash
# AWS CodeCommit 전용 자격증명 헬퍼 등록
# → git push/pull 시 자동으로 AWS 임시 자격증명을 발급받아 인증
git config --global credential.helper '!aws --profile my-profile codecommit credential-helper $@'

# URL 경로별로 자격증명을 구분하도록 설정 (여러 CodeCommit 저장소 사용 시 필요)
git config --global credential.UseHttpPath true
```

---

## 2-2단계: ArgoCD SSH known hosts 설정 (수동)

> ArgoCD가 CodeCommit SSH 서버를 처음 접속할 때 "이 서버를 믿어도 되나요?" 라고 확인합니다.
> 미리 CodeCommit의 SSH 호스트 키를 신뢰 목록에 등록해두어야 합니다.
> 이 단계를 건너뛰면 ArgoCD가 `knownhosts: key is unknown` 오류로 저장소를 읽지 못합니다.

```bash
# EKS 클러스터 이름 조회 (education-eks-로 시작하는 클러스터)
CLUSTER_NAME=$(aws eks list-clusters --region us-east-1 --profile my-profile \
  --query 'clusters[?contains(@, `education-eks`)]' --output text)

# 로컬 kubectl이 이 클러스터를 바라보도록 kubeconfig 업데이트
aws eks update-kubeconfig --region us-east-1 --profile my-profile --name $CLUSTER_NAME
```

**기대 출력:**
```
Added new context arn:aws:eks:us-east-1:123456789012:cluster/education-eks-xxxxxxxx to /Users/yourname/.kube/config
```

```bash
# CodeCommit SSH 서버의 호스트 키 수집 (신뢰할 서버 정보)
CODECOMMIT_KEYS=$(ssh-keyscan git-codecommit.us-east-1.amazonaws.com 2>/dev/null | grep -v "^#")

# ArgoCD의 현재 신뢰 호스트 목록 조회
EXISTING=$(kubectl get configmap argocd-ssh-known-hosts-cm -n argocd \
  -o jsonpath='{.data.ssh_known_hosts}')

# 기존 목록에 CodeCommit 호스트 키 추가
NEW_HOSTS="${EXISTING}
${CODECOMMIT_KEYS}"

# ArgoCD ConfigMap 업데이트
kubectl patch configmap argocd-ssh-known-hosts-cm -n argocd \
  --type merge \
  -p "{\"data\":{\"ssh_known_hosts\":$(echo "$NEW_HOSTS" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}}"

# argocd-repo-server 재시작 — 변경된 ConfigMap 반영
kubectl rollout restart deployment argocd-repo-server -n argocd

# 재시작 완료까지 대기
kubectl rollout status deployment argocd-repo-server -n argocd --timeout=90s
```

**기대 출력:**
```
configmap/argocd-ssh-known-hosts-cm patched
deployment.apps/argocd-repo-server restarted
Waiting for deployment "argocd-repo-server" rollout to finish: 1 old replicas are pending termination...
deployment "argocd-repo-server" successfully rolled out
```

---

## 2-3단계: CodeCommit에 소스 코드 복제 및 push (수동)

### javaspring (앱 소스) 복제 및 push

> GitHub의 원본 소스를 CodeCommit으로 복사합니다.
> push 즉시 EventBridge가 감지 → CodePipeline 자동 시작됩니다.

```bash
# terraform output에서 CodeCommit URL 읽기
JAVASPRING_URL=$(terraform output -raw codecommit_javaspring_url)

# GitHub에서 javaspring 소스 코드 클론
git clone https://github.com/gasbugs/javaspring
cd javaspring

# CodeCommit을 원격 저장소로 추가
git remote add codecommit $JAVASPRING_URL

# CodeCommit으로 push (osxkeychain 간섭 방지를 위해 credential.helper 명시)
git -c credential.helper="" \
    -c "credential.helper=!aws --profile my-profile codecommit credential-helper \$@" \
    push codecommit main
cd ..
```

**기대 출력:**
```
Cloning into 'javaspring'...
remote: Counting objects: 15, done.
To https://git-codecommit.us-east-1.amazonaws.com/v1/repos/javaspring
 * [new branch]      main -> main
```

> push 직후 CodePipeline이 자동 트리거됩니다. Java Spring Boot는 Maven 컴파일을 포함하므로 빌드에 **5~10분** 소요됩니다.

### javaspring-apps (K8s 매니페스트) 복제 및 push

> Kubernetes 배포 설정 파일을 CodeCommit에 올립니다.
> ArgoCD가 이 저장소를 감시하다가 변경을 감지하면 EKS에 자동 배포합니다.

```bash
# terraform output에서 URL 읽기
JAVASPRING_APPS_URL=$(terraform output -raw codecommit_javaspring_apps_url)
ECR_URL=$(terraform output -raw ecr_repository_url)

# GitHub에서 javaspring-apps 매니페스트 클론
git clone https://github.com/gasbugs/javaspring-apps
cd javaspring-apps

# deployment.yaml의 이미지 주소를 실제 ECR URL로 교체 (macOS/Linux 호환)
sed -i.bak "s|image:.*|image: $ECR_URL:latest|g" deployment.yaml && rm -f deployment.yaml.bak

# service.yaml의 서비스 타입을 LoadBalancer로 설정 (외부 접속용 ELB 자동 생성)
sed -i.bak "s|type: NodePort|type: LoadBalancer|g" service.yaml && rm -f service.yaml.bak

git add deployment.yaml service.yaml
git commit -m "ci: update image to ECR URL & service type to LoadBalancer"

git remote add codecommit $JAVASPRING_APPS_URL
git -c credential.helper="" \
    -c "credential.helper=!aws --profile my-profile codecommit credential-helper \$@" \
    push codecommit main
cd ..
```

**기대 출력:**
```
Cloning into 'javaspring-apps'...
[main xxxxxxx] ci: update image to ECR URL & service type to LoadBalancer
 2 files changed, 2 insertions(+), 2 deletions(-)
To https://git-codecommit.us-east-1.amazonaws.com/v1/repos/javaspring-apps
 * [new branch]      main -> main
```

---

## 3단계: 파이프라인 실행 확인

> CodeBuild가 Java 소스를 컴파일하고 Docker 이미지를 빌드·push하는 단계입니다.

```bash
# 파이프라인 이름 조회 (javaspring이 포함된 파이프라인)
PIPELINE_NAME=$(aws codepipeline list-pipelines --region us-east-1 --profile my-profile \
  --query 'pipelines[?contains(name, `javaspring`)].name' --output text)

# 각 단계(Source, Build) 상태 확인
aws codepipeline get-pipeline-state --name $PIPELINE_NAME \
  --region us-east-1 --profile my-profile \
  --query 'stageStates[*].[stageName,latestExecution.status]' --output table
```

**기대 출력 (빌드 중):**
```
-------------------------
|   GetPipelineState    |
+---------+-------------+
|  Source |  Succeeded  |
|  Build  |  InProgress |
+---------+-------------+
```

**기대 출력 (빌드 완료):**
```
-------------------------
|   GetPipelineState    |
+---------+-------------+
|  Source |  Succeeded  |
|  Build  |  Succeeded  |
+---------+-------------+
```

```bash
# ECR에 이미지가 정상 push됐는지 확인 (이미지 태그와 push 시각 표시)
aws ecr describe-images --repository-name javaspring \
  --region us-east-1 --profile my-profile \
  --query 'imageDetails[].[imageTags[0],imagePushedAt]' --output table
```

**기대 출력:**
```
--------------------------------------------------
|               DescribeImages                   |
+------------+------------------------------------+
|  a1b2c3d   |  2026-04-17T19:48:16.499000+09:00  |
+------------+------------------------------------+
```

---

## 4단계: ArgoCD 및 배포 확인

> ArgoCD가 javaspring-apps 저장소 변경을 감지하고 EKS에 자동 배포합니다.

```bash
# ArgoCD Application 동기화 상태 확인
# SYNC STATUS: Synced = Git과 클러스터 상태 일치
# HEALTH STATUS: Healthy = 파드 정상 실행 중
kubectl get application javaspring-app -n argocd
```

**기대 출력:**
```
NAME             SYNC STATUS   HEALTH STATUS
javaspring-app   Synced        Healthy
```

```bash
# ArgoCD 웹 UI 접속 주소 확인 (EXTERNAL-IP 컬럼의 도메인 주소로 브라우저 접속)
kubectl get svc -n argocd argocd-server
```

**기대 출력:**
```
NAME            TYPE           CLUSTER-IP      EXTERNAL-IP                                                              PORT(S)                      AGE
argocd-server   LoadBalancer   172.20.x.x      xxxxxxxx.us-east-1.elb.amazonaws.com   80:xxxxx/TCP,443:xxxxx/TCP   30m
```

```bash
# ArgoCD 웹 UI 초기 로그인 비밀번호 확인 (사용자명: admin)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

**기대 출력:**
```
aBcDeFgHiJkL    ← 이 값이 ArgoCD 초기 비밀번호 (매 배포마다 다름)
```

```bash
# EKS에 배포된 파드 상태 확인 (Running = 정상)
kubectl get pods -n javaspring-app
```

**기대 출력:**
```
NAME                          READY   STATUS    RESTARTS   AGE
javaspring-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
javaspring-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
```

```bash
# 서비스 확인 — EXTERNAL-IP(ELB 주소)로 브라우저 또는 curl 접속
kubectl get svc -n javaspring-app
```

**기대 출력:**
```
NAME         TYPE           CLUSTER-IP     EXTERNAL-IP                                                              PORT(S)        AGE
javaspring   LoadBalancer   172.20.x.x     xxxxxxxx.us-east-1.elb.amazonaws.com   80:xxxxx/TCP   3m
```

```bash
# HTTP 응답 확인 (ELB DNS가 전파되기까지 1~2분 소요될 수 있음)
LB=$(kubectl get svc javaspring -n javaspring-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$LB/
```

**기대 출력:**
```
Hello, Web Docker Multi-Stage!
```

---

## 5단계: GitOps 자동 배포 테스트

> 코드를 수정하고 push하면 빌드 → 이미지 교체 → 자동 배포까지 자동으로 이루어지는지 검증합니다.

### 5-1. 소스 코드 변경 및 push

```bash
cd javaspring

# App.java의 응답 문자열 변경 (파일을 직접 수정하거나 아래 명령어 사용)
# ← 응답 문자열을 원하는 내용으로 수정하세요
# 예: "Hello, World!" → "Hello, Updated!"
vi src/main/java/com/example/App.java

# AppTest.java의 기대 문자열도 App.java와 동일하게 수정 (테스트가 실패하면 빌드 실패)
vi src/test/java/com/example/AppTest.java

git add .
git commit -m "test: 응답 문자열 변경 — CI 파이프라인 트리거"

# CodeCommit에 push → EventBridge가 즉시 감지 → CodePipeline 자동 시작
git -c credential.helper="" \
    -c "credential.helper=!aws --profile my-profile codecommit credential-helper \$@" \
    push codecommit main
cd ..
```

**기대 출력:**
```
[main xxxxxxx] test: 응답 문자열 변경 — CI 파이프라인 트리거
To https://git-codecommit.us-east-1.amazonaws.com/v1/repos/javaspring
   xxxxxxx..xxxxxxx  main -> main
```

### 5-2. 빌드 완료 및 자동 배포 확인

```bash
# 파이프라인 상태 확인 (Build Succeeded 될 때까지 대기 — 약 5~10분)
PIPELINE_NAME=$(aws codepipeline list-pipelines --region us-east-1 --profile my-profile \
  --query 'pipelines[?contains(name, `javaspring`)].name' --output text)

aws codepipeline get-pipeline-state --name $PIPELINE_NAME \
  --region us-east-1 --profile my-profile \
  --query 'stageStates[*].[stageName,latestExecution.status]' --output table
```

**기대 출력 (빌드 완료):**
```
-------------------------
|   GetPipelineState    |
+---------+-------------+
|  Source |  Succeeded  |
|  Build  |  Succeeded  |
+---------+-------------+
```

```bash
# javaspring-apps의 deployment.yaml이 새 이미지 태그로 자동 업데이트됐는지 확인
# (update_apps.sh가 빌드 후 자동으로 커밋·push함)
aws codecommit get-file --repository-name javaspring-apps \
  --file-path deployment.yaml \
  --region us-east-1 --profile my-profile \
  --query 'fileContent' --output text | base64 -d | grep image
```

**기대 출력:**
```
  image: 123456789012.dkr.ecr.us-east-1.amazonaws.com/javaspring:a1b2c3d
                                                                  ^^^^^^^ 커밋 해시 7자리 태그로 자동 변경됨
```

```bash
# ArgoCD가 변경을 감지하고 자동 배포 중인지 확인
# OutOfSync → ArgoCD가 변경을 감지하고 배포 진행 중
# Synced    → 배포 완료
kubectl get application javaspring-app -n argocd
```

**기대 출력 (배포 진행 중):**
```
NAME             SYNC STATUS   HEALTH STATUS
javaspring-app   OutOfSync     Healthy
```

**기대 출력 (배포 완료):**
```
NAME             SYNC STATUS   HEALTH STATUS
javaspring-app   Synced        Healthy
```

```bash
# 새 파드가 Rolling Update로 교체되는 과정 실시간 확인
# 기존 파드가 Terminating되고 새 파드가 ContainerCreating → Running으로 전환됨
kubectl get pods -n javaspring-app
```

**기대 출력 (롤링 업데이트 중):**
```
NAME                          READY   STATUS              RESTARTS   AGE
javaspring-xxxxxxxxxx-old1    1/1     Running             0          10m   ← 기존 파드
javaspring-xxxxxxxxxx-old2    1/1     Running             0          10m   ← 기존 파드
javaspring-yyyyyyyyyy-new1    0/1     ContainerCreating   0          5s    ← 새 파드 생성 중
```

```bash
# ArgoCD 즉시 동기화 (폴링 3분을 기다리지 않고 강제 반영)
kubectl annotate application javaspring-app -n argocd \
  argocd.argoproj.io/refresh="hard" --overwrite

# 새 코드가 배포됐는지 HTTP 응답으로 최종 확인
LB=$(kubectl get svc javaspring -n javaspring-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$LB/
```

**기대 출력:**
```
Hello, Updated!    ← App.java에서 수정한 내용이 반영됨
```

---

## 6단계: 리소스 삭제

> 실습 완료 후 반드시 삭제하세요. EKS 클러스터는 시간당 비용이 발생합니다.

```bash
# ArgoCD Application 먼저 삭제 (ArgoCD가 관리하는 K8s 리소스를 정리)
kubectl delete application javaspring-app -n argocd
```

**기대 출력:**
```
application.argoproj.io "javaspring-app" deleted
```

```bash
# 모든 AWS 리소스 삭제 (EKS, ECR, CodePipeline, S3 등 86개 리소스)
terraform destroy -auto-approve
```

**기대 출력 (완료):**
```
...
Destroy complete! Resources: 86 destroyed.
```

---

## buildspec.yml 구조

`javaspring` 레포 루트의 `buildspec.yml`이 CodeBuild 빌드 명세입니다:

```yaml
version: 0.2
phases:
  pre_build:
    commands:
      # ECR 로그인 — Docker 이미지를 push하기 위한 인증
      - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $ECR_REPO_URI
      # 이미지 태그 = 커밋 해시 앞 7자리 (예: a1b2c3d)
      # 태그가 변경되어야 ArgoCD가 새 배포로 인식함
      - IMAGE_TAG=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c1-7)
      # CodeCommit에 push하기 위한 git 인증 설정
      - git config --global credential.helper '!aws codecommit credential-helper $@'
      - git config --global user.email codebuild@cicd
      - git config --global user.name CodeBuild
  build:
    commands:
      # Dockerfile의 멀티 스테이지 빌드 실행
      # 1단계(maven): Maven으로 Java 소스 컴파일 + 단위 테스트 + JAR 생성 (~5분)
      # 2단계(jre):   JAR 파일만 가져와 경량 실행 이미지 생성 (이미지 크기 최소화)
      - docker build -t $ECR_REPO_URI:$IMAGE_TAG .
      - docker tag $ECR_REPO_URI:$IMAGE_TAG $ECR_REPO_URI:latest
  post_build:
    commands:
      # ECR에 이미지 push — 태그 버전과 latest 두 개 모두 push
      - docker push $ECR_REPO_URI:$IMAGE_TAG
      - docker push $ECR_REPO_URI:latest
      # update_apps.sh: javaspring-apps 레포를 클론해서
      # deployment.yaml의 이미지 태그를 새 커밋 해시로 자동 교체 후 push
      # → ArgoCD가 변경을 감지 → EKS 자동 배포
      - bash update_apps.sh
```

---

## 주의사항

- **테스트 완료 즉시 `terraform destroy` 실행 필수** — EKS 클러스터는 시간당 비용 발생
- Java 멀티 스테이지 빌드는 Maven 의존성 다운로드로 **첫 빌드가 5~10분** 소요
- CodeBuild `build_timeout = 20`으로 Flask(10분)보다 두 배 설정
- ArgoCD SSH known hosts 설정(2-2단계)을 빠뜨리면 ArgoCD가 저장소를 읽지 못함
- App.java 응답 문자열 변경 시 AppTest.java의 기대값도 동일하게 수정해야 빌드 성공
- `push_to_codecommit.sh` 스크립트를 사용하면 2-1 ~ 2-3단계를 자동으로 처리
