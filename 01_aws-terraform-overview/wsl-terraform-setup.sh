#!/bin/bash
set -e

echo "=============================="
echo " 1. Docker 설치"
echo "=============================="
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
echo "Docker 설치 완료"

echo ""
echo "=============================="
echo " 2. AWS CLI 설치"
echo "=============================="
sudo apt-get install -y unzip curl
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -oq awscliv2.zip

if aws --version &>/dev/null; then
  echo "AWS CLI가 이미 설치되어 있습니다. --update로 업데이트합니다."
  sudo ./aws/install --update
else
  sudo ./aws/install
fi

rm -rf awscliv2.zip aws/
echo "AWS CLI 설치 완료"

echo ""
echo "=============================="
echo " 3. Terraform 설치"
echo "=============================="
sudo apt-get install -y gnupg software-properties-common

wget -O- https://apt.releases.hashicorp.com/gpg | \
  gpg --dearmor | \
  sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt-get update && sudo apt-get install -y terraform
echo "Terraform 설치 완료"

echo ""
echo "=============================="
echo " 4. Terraform 프로바이더 캐시 설정"
echo "=============================="

TF_CACHE_DIR="$HOME/.terraform.d/plugin-cache"
TF_RC_FILE="$HOME/.terraformrc"

mkdir -p "$TF_CACHE_DIR"
echo "캐시 디렉토리 생성: $TF_CACHE_DIR"

if grep -q "plugin_cache_dir" "$TF_RC_FILE" 2>/dev/null; then
  echo ".terraformrc에 이미 plugin_cache_dir 설정이 존재합니다. 건너뜁니다."
else
  cat >> "$TF_RC_FILE" <<EOF

plugin_cache_dir = "$TF_CACHE_DIR"
EOF
  echo ".terraformrc 설정 완료: $TF_RC_FILE"
fi

if grep -q "TF_PLUGIN_CACHE_DIR" "$HOME/.bashrc" 2>/dev/null; then
  echo ".bashrc에 이미 TF_PLUGIN_CACHE_DIR 설정이 존재합니다. 건너뜁니다."
else
  echo "export TF_PLUGIN_CACHE_DIR=\"$TF_CACHE_DIR\"" >> "$HOME/.bashrc"
  echo ".bashrc 환경변수 등록 완료"
fi

export TF_PLUGIN_CACHE_DIR="$TF_CACHE_DIR"
echo "Terraform 프로바이더 캐시 설정 완료"

echo ""
echo "=============================="
echo " 5. Git 설치 및 실습 저장소 clone"
echo "=============================="
sudo apt-get install -y git
echo "Git 설치 완료"

REPO_URL="https://github.com/gasbugs/mulcam-aws-infra-automation-terraform"
REPO_DIR="$HOME/mulcam-aws-infra-automation-terraform"

if [ -d "$REPO_DIR" ]; then
  echo "저장소가 이미 존재합니다. git pull로 업데이트합니다."
  git -C "$REPO_DIR" pull
else
  git clone "$REPO_URL" "$REPO_DIR"
  echo "저장소 clone 완료: $REPO_DIR"
fi

echo ""
echo "=============================="
echo " 6. Node.js / npm 설치"
echo "=============================="
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
echo "Node.js / npm 설치 완료"

echo ""
echo "=============================="
echo " 7. Gemini CLI 설치"
echo "=============================="
sudo npm install -g @google/gemini-cli
echo "Gemini CLI 설치 완료"

echo ""
echo "=============================="
echo " 8. HashiCorp Agent Skills 설치"
echo "=============================="

echo "[8-1] Gemini CLI용 HashiCorp Agent Skills 설치"
npx skills add hashicorp/agent-skills -a gemini-cli
echo "Gemini CLI용 스킬 설치 완료"

echo ""
echo "[8-2] Claude Code용 HashiCorp Agent Skills 설치"
npx skills add hashicorp/agent-skills -a claude-code
echo "Claude Code용 스킬 설치 완료"

echo ""
echo "============================================"
echo " 설치 버전 최종 확인"
echo "============================================"
echo ""

check_version() {
  local name=$1
  local cmd=$2
  local version
  version=$(eval "$cmd" 2>/dev/null)
  if [ -n "$version" ]; then
    printf "  %-20s %s\n" "$name" "$version"
  else
    printf "  %-20s [확인 실패 - 설치 상태 점검 필요]\n" "$name"
  fi
}

check_version "Docker"      "sudo docker version --format '{{.Server.Version}}'"
check_version "AWS CLI"     "aws --version"
check_version "Terraform"   "terraform -version | head -1"
check_version "Git"         "git --version"
check_version "Node.js"     "node -v"
check_version "npm"         "npm -v"
check_version "Gemini CLI"  "gemini --version"

echo ""
echo "============================================"
echo " 모든 설치 및 설정이 완료되었습니다."
echo "============================================"
echo ""
echo "[Terraform 캐시]   $TF_CACHE_DIR"
echo "[Terraform RC]     $TF_RC_FILE"
echo "[실습 저장소]      $REPO_DIR"
echo ""
echo "※ 환경변수 즉시 적용: source ~/.bashrc"
echo "※ Gemini CLI 인증:    gemini (최초 실행 시 Google 계정 로그인)"