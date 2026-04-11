# EC2 for Secrets Manager

## 개요

`managing-secrets-manager-with-terraform` 실습에서 생성한 시크릿에 EC2 인스턴스가 접근하는 방법을 실습합니다. EC2 IAM 인스턴스 프로파일을 통해 자격증명 파일 없이 특정 시크릿 ARN에 대한 최소 권한 읽기 접근을 구성하고, SSH로 접속한 뒤 AWS CLI로 시크릿 값을 직접 조회합니다.

## 학습 목표

- IAM 인스턴스 프로파일을 통해 EC2에 AWS 서비스 접근 권한을 부여하는 방법 이해
- 특정 시크릿 ARN만 허용하는 최소 권한(Least Privilege) IAM 정책 작성 방법 습득
- EC2 내부에서 AWS CLI로 Secrets Manager 시크릿을 조회하는 방법 이해
- TLS 프로바이더로 SSH 키를 자동 생성하고 로컬에 저장하는 패턴 습득

## 생성되는 AWS 리소스

| 리소스 | 이름 | 설명 |
|--------|------|------|
| `aws_security_group` | `ssh-access-sg` | EC2 SSH 접속(22번 포트) 허용 보안 그룹 |
| `aws_key_pair` | `ec2-key-{랜덤}` | EC2 SSH 접속용 키페어 (TLS 프로바이더로 자동 생성) |
| `aws_instance` | `{env}-secrets-demo-ec2` | Secrets Manager 시크릿 조회 실습용 EC2 (AL2023, t3.micro) |
| `aws_iam_role` | `{env}-ec2-secrets-manager-role` | EC2에 부여하는 IAM 역할 |
| `aws_iam_instance_profile` | `{env}-ec2-secrets-manager-profile` | IAM 역할을 EC2에 연결하는 인스턴스 프로파일 |
| `aws_iam_policy` | `{env}-secrets-manager-access-policy` | 지정된 시크릿 ARN에 대한 읽기 전용 최소 권한 정책 |

## 사전 요구사항

- AWS CLI 설정 (`my-profile` 프로파일)
- Terraform >= 1.13.4
- **`managing-secrets-manager-with-terraform` 실습을 먼저 완료해야 합니다.**
  - 해당 프로젝트에서 `terraform output secret_arn` 명령으로 시크릿 ARN을 확인한 뒤 이 실습에 입력합니다.
- `secret_arn` 변수는 기본값이 없으므로 반드시 직접 지정 필요

## 사용 방법

```bash
terraform init
terraform plan
terraform apply
```

이전 실습의 시크릿 ARN을 변수로 전달합니다.

```bash
terraform apply -var="secret_arn=arn:aws:secretsmanager:us-east-1:123456789012:secret:my-example-secret-XXXX"
```

### 주요 출력값

- `ec2_public_ip`: EC2 인스턴스의 공인 IP 주소
- `ssh_command`: EC2에 SSH로 접속하는 완성된 명령어
- `private_key_pem`: EC2 SSH 접속용 프라이빗 키 (민감 정보 — `terraform output -raw private_key_pem`으로 확인)

### EC2 접속 후 시크릿 조회 방법

SSH 접속 후 아래 명령으로 시크릿 값을 확인할 수 있습니다.

```bash
# EC2 접속
ssh -i ec2-key.pem ec2-user@<ec2_public_ip>

# EC2 내부에서 시크릿 조회
aws secretsmanager get-secret-value \
  --secret-id "<secret_arn>" \
  --region us-east-1
```

## 정리

```bash
terraform destroy
```

## 참고사항

- 이 프로젝트는 Default VPC를 사용합니다. 별도의 VPC 생성 없이 기존 Default VPC에 EC2를 배치합니다.
- IAM 정책은 입력받은 `secret_arn`에 해당하는 시크릿 한 개에만 `secretsmanager:GetSecretValue` 권한을 부여합니다. 다른 시크릿은 접근이 차단됩니다.
- SSH 보안 그룹은 학습 편의를 위해 전체 IP(`0.0.0.0/0`)를 허용합니다. 실제 운영 환경에서는 접속할 IP 대역으로 제한하세요.
- `ec2-key.pem` 파일은 `terraform apply` 이후 프로젝트 디렉토리에 자동 생성됩니다. 파일 권한이 `0400`으로 설정되어 SSH 접속 시 별도 `chmod` 없이 바로 사용 가능합니다.
