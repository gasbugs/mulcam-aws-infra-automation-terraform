# ECR Pull-Through Cache Practice

이 프로젝트는 Amazon ECR 프라이빗 리포지토리, Docker Hub Pull-Through Cache Rule, 선택형 Secrets Manager 자격 증명, 검증용 EC2 인스턴스를 함께 생성하는 실습입니다. 목표는 "리소스가 생성되었다" 수준이 아니라, 실제로 SSH 접속과 캐시 pull이 되는지까지 확인하는 것입니다.

## 실습 목표

- 실습용 ECR 리포지토리를 생성한다.
- Docker Hub Pull-Through Cache Rule을 생성한다.
- 선택적으로 Docker Hub 인증 정보를 Secrets Manager에 저장한다.
- 검증용 EC2 인스턴스에 SSH로 접속한다.
- ECR Pull-Through Cache 경로로 이미지를 실제로 pull해 캐시 동작을 확인한다.

## 생성 리소스 정리

- `aws_ecr_repository.main`
  실습용 프라이빗 ECR 리포지토리입니다. 직접 이미지를 push하는 흐름을 추가로 연습할 때 사용합니다.
- `aws_ecr_pull_through_cache_rule.docker_hub`
  Docker Hub 이미지를 ECR 경유로 가져오기 위한 캐시 규칙입니다.
- `aws_secretsmanager_secret.docker_hub`
  `docker_hub_username`, `docker_hub_access_token`을 넣은 경우에만 생성됩니다.
- `aws_secretsmanager_secret_version.docker_hub`
  위 시크릿의 실제 버전 값입니다.
- `tls_private_key.instance`
  실습용 EC2 SSH 접속을 위해 Terraform이 동적으로 생성하는 개인 키입니다.
- `aws_key_pair.instance`
  AWS에 등록되는 공개 키입니다.
- `aws_iam_role.instance`, `aws_iam_instance_profile.instance`
  EC2가 ECR 로그인과 pull 검증을 직접 수행할 수 있도록 하는 IAM 권한입니다.
- `aws_security_group.instance`
  SSH 접속을 허용하는 보안 그룹입니다.
- `aws_instance.main`
  Amazon Linux 2023 기반 검증용 EC2 인스턴스입니다. 부팅 시 Docker와 AWS CLI를 설치합니다.

## 사전 준비

- AWS CLI에 `my-profile` 프로파일이 설정되어 있어야 합니다.
- 로컬에 `terraform`, `aws`, `ssh` 명령이 있어야 합니다.
- Docker Hub Pull-Through Cache Rule 생성을 위해 `docker_hub_username`, `docker_hub_access_token`이 필요합니다.
- 현재 설정의 SSH 허용 CIDR 기본값은 `0.0.0.0/0`입니다. 실습 후에는 좁히는 것이 좋습니다.

## Docker Hub 인증 준비

이 프로젝트는 실제 배포 테스트 결과, 현재 AWS ECR이 `registry-1.docker.io`에 대해 인증 없는 Pull-Through Cache Rule 생성을 허용하지 않았습니다. 따라서 아래 값을 먼저 준비해야 합니다.

1. Docker Hub에 로그인합니다.
2. `Account Settings -> Personal Access Tokens`로 이동합니다.
3. 새 토큰을 생성합니다.
4. 토큰 값과 Docker Hub 사용자명을 `terraform.tfvars`에 넣습니다.

예시:

```hcl
docker_hub_username     = "YOUR_DOCKER_HUB_USERNAME"
docker_hub_access_token = "YOUR_DOCKER_HUB_PAT"
```

## 권장 변수 예시

기본 실습 예시 파일로 [`terraform.tfvars.example`](/Users/gasbugs/mulcam-aws-infra-automation-terraform/08_ecs-cluster-mgmt/ecr-pull-through-cache/terraform.tfvars.example)를 추가해두었습니다. 이를 복사해 로컬 `terraform.tfvars`를 만든 뒤 placeholder를 실제 값으로 바꿉니다.

```hcl
aws_region              = "us-east-1"
project_name            = "ecr-cache-lab"
repository_name         = "my-ecr-repo"
pull_through_cache_prefix = "docker-hub"
allowed_ssh_cidr_blocks = ["YOUR_PUBLIC_IP/32"]

docker_hub_username     = "YOUR_DOCKER_HUB_USERNAME"
docker_hub_access_token = "YOUR_DOCKER_HUB_PAT"
```

## 배포 절차

1. 초기화합니다.

```bash
terraform init -upgrade
```

2. 변경 계획을 확인합니다.

```bash
terraform plan
```

3. 리소스를 생성합니다.

```bash
terraform apply
```

4. 주요 출력값을 확인합니다.

```bash
terraform output aws_ecr_repository_url
terraform output docker_hub_pull_through_cache_rule
terraform output instance_id
terraform output instance_public_dns
terraform output -raw instance_ssh_private_key_pem
```

## 동작 검증 절차

아래 검증은 반드시 순서대로 진행하는 것을 권장합니다.

### 1. ECR 리포지토리 생성 확인

로컬에서 아래 명령으로 리포지토리가 생성되었는지 확인합니다.

```bash
aws ecr describe-repositories \
  --profile my-profile \
  --region us-east-1 \
  --repository-names my-ecr-repo
```

정상이라면 리포지토리 URI와 ARN이 반환됩니다.

### 2. Pull-Through Cache Rule 생성 확인

```bash
aws ecr describe-pull-through-cache-rules \
  --profile my-profile \
  --region us-east-1
```

확인 포인트:

- `ecrRepositoryPrefix`가 `docker-hub`인지 확인
- `upstreamRegistryUrl`이 `registry-1.docker.io`인지 확인

### 3. Secrets Manager 생성 확인

```bash
aws secretsmanager list-secrets \
  --profile my-profile \
  --region us-east-1 \
  --query "SecretList[?contains(Name, 'ecr-pullthroughcache')].Name"
```

정상이라면 `ecr-pullthroughcache/<project_name>-docker-hub-cred` 형식의 이름이 조회됩니다.

시크릿 값 구조도 확인할 수 있습니다.

```bash
aws secretsmanager get-secret-value \
  --profile my-profile \
  --region us-east-1 \
  --secret-id ecr-pullthroughcache/ecr-cache-lab-docker-hub-cred
```

확인 포인트:

- JSON 안에 `username`
- JSON 안에 `accessToken`

### 4. EC2 인스턴스 SSH 접속 확인

Terraform 출력으로 받은 개인 키를 파일로 저장한 뒤 권한을 조정합니다.

```bash
terraform output -raw instance_ssh_private_key_pem > ecr-cache-lab.pem
chmod 400 ecr-cache-lab.pem
```

퍼블릭 DNS를 확인합니다.

```bash
terraform output instance_public_dns
```

SSH 접속합니다.

```bash
ssh -i ecr-cache-lab.pem ec2-user@$(terraform output -raw instance_public_dns)
```

정상이라면 Amazon Linux 2023 셸에 접속됩니다.

접속 후 최소 확인:

```bash
cat /etc/os-release
hostname
curl -I https://public.ecr.aws
```

확인 포인트:

- OS가 Amazon Linux 2023인지 확인
- 외부 네트워크에 outbound 연결이 되는지 확인

### 5. Pull-Through Cache 실제 동작 확인

이제 EC2에 SSH로 접속한 뒤 인스턴스 자체에서 ECR 로그인과 pull을 수행할 수 있습니다.

1. EC2에 SSH 접속합니다.

```bash
ssh -i ecr-cache-lab.pem ec2-user@$(terraform output -raw instance_public_dns)
```

2. 계정 ID를 조회합니다.

```bash
aws sts get-caller-identity --query Account --output text
```

3. ECR 로그인합니다.

```bash
aws ecr get-login-password --region us-east-1 | docker login \
  --username AWS \
  --password-stdin ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com
```

4. 캐시 경로로 Docker Hub 이미지를 pull합니다.

```bash
docker pull ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/docker-hub/library/nginx:latest
```

정상이라면 첫 pull 시 ECR이 Docker Hub에서 이미지를 가져와 캐시합니다.

5. EC2 안에서 이미지가 내려받아졌는지 확인합니다.

```bash
docker images | grep nginx
```

6. 로컬에서 ECR에 캐시 리포지토리가 생겼는지 확인합니다.

```bash
aws ecr describe-repositories \
  --profile my-profile \
  --region us-east-1 \
  --query "repositories[?contains(repositoryName, 'docker-hub')].repositoryName"
```

확인 포인트:

- `docker-hub/library/nginx` 형태 리포지토리가 조회되는지 확인

## 전체 검증 체크리스트

- `terraform apply`가 성공했다.
- ECR 리포지토리가 조회된다.
- Pull-Through Cache Rule이 조회된다.
- Docker Hub 자격 증명을 넣은 경우 Secrets Manager 시크릿이 조회된다.
- EC2 인스턴스에 SSH 접속이 된다.
- EC2에서 `aws sts get-caller-identity`가 성공한다.
- EC2에서 `docker login`이 성공한다.
- `docker pull ACCOUNT_ID.dkr.ecr.<region>.amazonaws.com/docker-hub/library/nginx:latest`가 성공한다.
- 캐시 대상 리포지토리가 ECR에 생성된다.

## 정리

```bash
terraform destroy
rm -f ecr-cache-lab.pem
```

## 참고

- Amazon Linux 2023 AMI는 SSM 공개 파라미터에서 최신값을 가져오므로 AMI ID를 직접 갱신할 필요가 없습니다.
- 이 프로젝트의 EC2에는 `AmazonEC2ContainerRegistryReadOnly` 권한이 연결되어 있어 ECR 로그인과 pull 검증을 직접 수행할 수 있습니다.
- 현재 코드는 Docker Hub 자격 증명이 없으면 `terraform apply` 단계에서 명시적으로 실패하도록 했습니다. 실배포 중간에 AWS API 에러로 실패하는 것보다 원인을 더 빨리 알기 위한 변경입니다.
