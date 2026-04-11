# terraform-iam-identity-center

## 개요

AWS IAM Identity Center(구 AWS SSO)를 Terraform으로 구성하는 실습 프로젝트입니다. 중앙 집중식 사용자 및 그룹 관리를 통해 여러 AWS 계정에 대한 접근 권한을 단일 포털에서 제어하는 방법을 학습합니다. 사용자 생성, 그룹 구성, 권한 집합(Permission Set) 정의, 계정 할당까지 SSO 전체 흐름을 코드로 자동화합니다.

## 학습 목표

- AWS IAM Identity Center의 구성 요소(사용자, 그룹, 권한 집합, 계정 할당) 이해
- Terraform으로 SSO 사용자 및 그룹을 생성하고 멤버십을 관리하는 방법 습득
- Permission Set을 통해 최소 권한 원칙(Least Privilege)을 적용하는 방법 학습
- 그룹 기반 권한 관리로 사용자 규모 확장 시 운영 효율을 높이는 설계 패턴 이해
- SSO 로그인 포털 URL을 통한 중앙 집중식 AWS 계정 접근 방식 파악

## 생성되는 AWS 리소스

| 리소스 | 이름 | 설명 |
|--------|------|------|
| `aws_identitystore_group` | `var.group_name` | SSO 사용자를 묶어 권한을 일괄 관리하는 Identity Store 그룹 |
| `aws_identitystore_user` | `var.user_display_name` | SSO 포털에 로그인할 수 있는 중앙 관리 사용자 계정 |
| `aws_identitystore_group_membership` | (자동 생성) | 사용자를 그룹에 연결하는 멤버십 설정 |
| `aws_ssoadmin_permission_set` | `ReadOnlyAccess` | 세션 시간 4시간의 읽기 전용 권한 집합 |
| `aws_ssoadmin_account_assignment` | (자동 생성) | 그룹에 Permission Set을 부여하고 AWS 계정에 할당 |

## 사전 요구사항

- AWS CLI 설정 (`my-profile` 프로파일)
- Terraform >= 1.13.4
- AWS 계정에 **IAM Identity Center가 활성화**되어 있어야 함 (AWS 콘솔에서 수동 활성화 필요)
- Identity Center 인스턴스 ARN 및 Identity Store ID 사전 조회 필요

### Identity Center 정보 조회 방법

```bash
# SSO 인스턴스 ARN 조회
aws sso-admin list-instances \
  --query 'Instances[0].InstanceArn' \
  --output text \
  --profile my-profile

# Identity Store ID 조회
aws sso-admin list-instances \
  --query 'Instances[0].IdentityStoreId' \
  --output text \
  --profile my-profile
```

## 사용 방법

```bash
terraform init
terraform plan
terraform apply
```

### 변수 입력 예시

`terraform apply` 실행 시 아래 변수들을 입력하거나 `terraform.tfvars` 파일로 미리 정의합니다.

```hcl
# terraform.tfvars 예시
sso_instance_arn  = "arn:aws:sso:::instance/ssoins-xxxxxxxxxxxxxxxxx"
identity_store_id = "d-xxxxxxxxxx"
group_name        = "dev-team"
user_display_name = "john.doe"
user_given_name   = "John"
user_family_name  = "Doe"
user_email        = "john.doe@example.com"
```

### 주요 출력값

- `group_id`: 생성된 IAM Identity Store 그룹의 고유 ID
- `user_id`: 생성된 SSO 사용자의 고유 ID
- `user_name`: SSO 로그인에 사용하는 사용자 이름
- `sso_login_url`: SSO 로그인 포털 URL (`https://<identity_store_id>.awsapps.com/start`)

## 정리

```bash
terraform destroy
```

## 참고사항

- IAM Identity Center는 **AWS Organizations** 마스터 계정 또는 위임된 관리자 계정에서만 활성화 및 관리할 수 있습니다. 일반 멤버 계정에서는 이 프로젝트를 실행할 수 없습니다.
- Identity Center 활성화는 Terraform으로 자동화되지 않으며, AWS 콘솔에서 수동으로 먼저 활성화해야 합니다.
- 생성된 SSO 사용자에게는 입력한 이메일 주소로 로그인 초대 메일이 발송됩니다.
- Permission Set의 세션 지속 시간은 `PT4H`(4시간)으로 설정되어 있으며, 필요에 따라 `main.tf`에서 변경 가능합니다.
- `terraform destroy` 실행 시 사용자, 그룹, 계정 할당이 모두 삭제됩니다. SSO 인스턴스 자체는 삭제되지 않습니다.
