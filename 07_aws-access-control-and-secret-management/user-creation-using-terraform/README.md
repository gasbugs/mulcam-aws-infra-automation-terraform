# IAM 사용자 생성 실습 (user-creation-using-terraform)

## 개요

Terraform을 사용하여 AWS IAM 사용자와 그룹을 생성하고, AWS 관리형 정책을 그룹에 연결하는 방법을 실습하는 프로젝트입니다. IAM 사용자에게 프로그래밍 방식 접근 키(Access Key / Secret Key)를 발급하여 AWS CLI 또는 SDK에서 사용할 수 있는 자격증명을 구성합니다. 사용자를 그룹에 소속시켜 권한을 일괄 관리하는 IAM 모범 사례를 학습할 수 있습니다.

## 학습 목표

- Terraform으로 IAM 사용자(`aws_iam_user`)를 생성하는 방법을 이해한다
- IAM 그룹(`aws_iam_group`)을 생성하고 사용자를 그룹에 추가(`aws_iam_group_membership`)하는 방법을 익힌다
- AWS 관리형 정책(Managed Policy)을 그룹에 연결(`aws_iam_group_policy_attachment`)하는 방법을 학습한다
- 프로그래밍 방식 접근 키(`aws_iam_access_key`)를 발급하고 민감 정보를 안전하게 출력하는 방법을 배운다
- IAM 사용자 경로(path)와 `force_destroy` 옵션 등 IAM 세부 설정을 이해한다

## 생성되는 AWS 리소스

| 리소스 | 이름 | 설명 |
|--------|------|------|
| `aws_iam_user` | `ec2_user` (기본값) | EC2 관리를 위한 IAM 사용자 (`/system/` 경로에 생성) |
| `aws_iam_access_key` | ec2_user_key | CLI/SDK에서 사용할 Access Key / Secret Key 자격증명 |
| `aws_iam_group` | `ec2-managers` (기본값) | EC2 관리 권한을 묶어 관리하는 IAM 그룹 |
| `aws_iam_group_membership` | ec2-group | IAM 사용자를 그룹에 연결하는 멤버십 |
| `aws_iam_group_policy_attachment` | — | 그룹에 `AmazonEC2FullAccess` AWS 관리형 정책 연결 |

## 사전 요구사항

- AWS CLI 설정 (`my-profile` 프로파일)
- Terraform >= 1.13.4

## 사용 방법

```bash
cd 07_aws-access-control-and-secret-management/user-creation-using-terraform
terraform init
terraform plan
terraform apply
```

### 주요 출력값

- `ec2_user_name`: 생성된 IAM 사용자의 이름
- `ec2_group_name`: 생성된 IAM 그룹의 이름
- `ec2_user_access_key_id`: AWS CLI 설정에 사용할 Access Key ID
- `ec2_user_secret_access_key`: Secret Access Key (민감 정보, `terraform output -raw ec2_user_secret_access_key`로 조회)

## 정리

```bash
terraform destroy
```

## 참고사항

- Secret Access Key는 Terraform 적용 직후에만 조회할 수 있으며, 이후에는 재발급이 필요합니다. `terraform output -raw ec2_user_secret_access_key` 명령으로 확인하세요.
- `aws_iam_user_login_profile` 리소스(웹 콘솔 로그인 비밀번호 설정)는 주석 처리되어 있습니다. 콘솔 로그인이 필요한 경우 주석을 해제하여 사용하세요.
- `force_destroy = false`로 설정되어 있으므로, 사용자를 삭제하기 전에 연결된 액세스 키 등 하위 리소스를 먼저 정리해야 합니다.
