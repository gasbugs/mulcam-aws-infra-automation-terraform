#!/usr/bin/env bash
# CodeCommit에 javaspring 앱 소스와 K8s 매니페스트를 push하는 스크립트
# terraform apply 완료 후 실행합니다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWS_REGION="us-east-1"
AWS_PROFILE="my-profile"
WORK_DIR="$(mktemp -d)"

# 스크립트 종료 시 임시 디렉터리 자동 삭제
trap 'rm -rf "$WORK_DIR"' EXIT

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ────────────────────────────────────────────────────────────
# 1단계: terraform output에서 URL 읽기
# ────────────────────────────────────────────────────────────
log "terraform output 읽는 중..."
cd "$SCRIPT_DIR"

JAVASPRING_URL=$(terraform output -raw codecommit_javaspring_url)
JAVASPRING_APPS_URL=$(terraform output -raw codecommit_javaspring_apps_url)
ECR_URL=$(terraform output -raw ecr_repository_url)

log "  javaspring      : $JAVASPRING_URL"
log "  javaspring-apps : $JAVASPRING_APPS_URL"
log "  ECR             : $ECR_URL"

# ────────────────────────────────────────────────────────────
# 2단계: git credential helper 설정 (osxkeychain 간섭 방지)
# ────────────────────────────────────────────────────────────
log "git credential helper 설정 중..."
git config --global credential.helper \
  "!aws --profile $AWS_PROFILE codecommit credential-helper \$@"
git config --global credential.UseHttpPath true

# ────────────────────────────────────────────────────────────
# 3단계: kubeconfig 업데이트 및 ArgoCD SSH known hosts 등록
# ────────────────────────────────────────────────────────────
log "EKS kubeconfig 업데이트 중..."
CLUSTER_NAME=$(aws eks list-clusters \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  --query 'clusters[?contains(@, `education-eks`)]' --output text)

if [ -z "$CLUSTER_NAME" ]; then
  echo "ERROR: education-eks 클러스터를 찾을 수 없습니다." >&2
  exit 1
fi

aws eks update-kubeconfig \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" --name "$CLUSTER_NAME"
log "  클러스터: $CLUSTER_NAME"

log "ArgoCD SSH known hosts에 CodeCommit 호스트 키 등록 중..."
CODECOMMIT_HOST="git-codecommit.${AWS_REGION}.amazonaws.com"

# CodeCommit SSH 호스트 키 수집 (rsa/ecdsa/ed25519 모두)
CODECOMMIT_KEYS=$(ssh-keyscan "$CODECOMMIT_HOST" 2>/dev/null | grep -v "^#")

if [ -z "$CODECOMMIT_KEYS" ]; then
  echo "ERROR: CodeCommit 호스트 키를 가져올 수 없습니다." >&2
  exit 1
fi

EXISTING=$(kubectl get configmap argocd-ssh-known-hosts-cm -n argocd \
  -o jsonpath='{.data.ssh_known_hosts}' 2>/dev/null || echo "")

# 이미 등록된 경우 스킵
if echo "$EXISTING" | grep -q "$CODECOMMIT_HOST"; then
  log "  CodeCommit 호스트 키가 이미 등록되어 있습니다. 스킵."
else
  NEW_HOSTS="${EXISTING}
${CODECOMMIT_KEYS}"

  MERGED_JSON=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" \
    <<< "$NEW_HOSTS")

  kubectl patch configmap argocd-ssh-known-hosts-cm -n argocd \
    --type merge \
    -p "{\"data\":{\"ssh_known_hosts\":${MERGED_JSON}}}"

  log "  argocd-repo-server 재시작 중..."
  kubectl rollout restart deployment argocd-repo-server -n argocd
  kubectl rollout status deployment argocd-repo-server -n argocd --timeout=120s
  log "  ArgoCD SSH known hosts 등록 완료"
fi

# ────────────────────────────────────────────────────────────
# 4단계: javaspring 앱 소스 → CodeCommit push
# ────────────────────────────────────────────────────────────
log "javaspring 앱 소스 클론 및 CodeCommit push 중..."
cd "$WORK_DIR"

git clone https://github.com/gasbugs/javaspring
cd javaspring

git remote add codecommit "$JAVASPRING_URL"
# osxkeychain 간섭 방지: credential.helper="" 로 전역 설정 우회
git -c credential.helper="" \
    -c "credential.helper=!aws --profile $AWS_PROFILE codecommit credential-helper \$@" \
    push codecommit main

log "  javaspring push 완료 — CodePipeline이 자동 트리거됩니다 (빌드 5~10분 소요)"
cd "$WORK_DIR"

# ────────────────────────────────────────────────────────────
# 5단계: javaspring-apps 매니페스트 → ECR URL 교체 후 push
# ────────────────────────────────────────────────────────────
log "javaspring-apps 매니페스트 클론 및 이미지 주소 업데이트 중..."
git clone https://github.com/gasbugs/javaspring-apps
cd javaspring-apps

# deployment.yaml의 image 필드를 ECR URL로 교체 (macOS/Linux 호환)
sed -i.bak "s|image:.*|image: ${ECR_URL}:latest|g" deployment.yaml
rm -f deployment.yaml.bak

# service.yaml의 서비스 타입을 LoadBalancer로 설정
sed -i.bak "s|type: NodePort|type: LoadBalancer|g" service.yaml
rm -f service.yaml.bak

git add deployment.yaml service.yaml
git commit -m "ci: update image to ECR URL & service type to LoadBalancer"

git remote add codecommit "$JAVASPRING_APPS_URL"
git -c credential.helper="" \
    -c "credential.helper=!aws --profile $AWS_PROFILE codecommit credential-helper \$@" \
    push codecommit main

log "  javaspring-apps push 완료"

# ────────────────────────────────────────────────────────────
# 완료 요약
# ────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  CodeCommit push 완료"
echo "============================================================"
echo "  파이프라인 상태 확인:"
echo "    PIPELINE=\$(aws codepipeline list-pipelines \\"
echo "      --region $AWS_REGION --profile $AWS_PROFILE \\"
echo "      --query 'pipelines[?contains(name,\`javaspring\`)].name' \\"
echo "      --output text)"
echo "    aws codepipeline get-pipeline-state --name \$PIPELINE \\"
echo "      --region $AWS_REGION --profile $AWS_PROFILE \\"
echo "      --query 'stageStates[*].[stageName,latestExecution.status]' \\"
echo "      --output table"
echo ""
echo "  ArgoCD 비밀번호:"
echo "    kubectl -n argocd get secret argocd-initial-admin-secret \\"
echo "      -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
echo "  파드 상태:"
echo "    kubectl get pods -n javaspring-app"
echo "============================================================"
