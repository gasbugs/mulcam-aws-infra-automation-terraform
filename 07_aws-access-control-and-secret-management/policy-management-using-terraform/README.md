# IAM 정책 및 역할 위임 실습 (policy-management-using-terraform)

## 개요

Terraform을 사용하여 커스텀 IAM 정책을 JSON 파일로 정의하고, IAM 역할(Role)을 생성하여 특정 사용자가 역할을 위임(AssumeRole)받는 구조를 실습하는 프로젝트입니다. S3 읽기 전용 권한을 가진 정책을 역할에 연결하고, 해당 역할을 위임받을 수 있는 IAM 사용자를 함께 생성합니다. IAM 정책과 역할의 관계, 그리고 `sts:AssumeRole` 메커니즘을 이해하는 데 초점을 맞춥니다.

## 학습 목표

- 외부 JSON 파일로 IAM 정책(`aws_iam_policy`)을 정의하고 Terraform에서 불러오는 방법을 학습한다
- IAM 역할(`aws_iam_role`)과 신뢰 정책(Trust Policy / `assume_role_policy`)의 개념을 이해한다
- `sts:AssumeRole`을 통해 사용자가 역할을 위임받는 구조를 실습한다
- `data "aws_caller_identity"`로 현재 계정 ID를 동적으로 참조하는 방법을 배운다
- IAM 역할에 정책을 연결(`aws_iam_role_policy_attachment`)하는 방법을 익힌다

## 생성되는 AWS 리소스

| 리소스 | 이름 | 설명 |
|--------|------|------|
| `aws_iam_policy` | S3ReadOnlyPolicy | S3 객체 읽기(`GetObject`) 및 버킷 목록 조회(`ListAllMyBuckets`) 허용 정책 |
| `aws_iam_role` | S3ReadOnlyRole | `example_user`가 위임받을 수 있는 S3 읽기 전용 IAM 역할 |
| `aws_iam_role_policy_attachment` | — | S3ReadOnlyPolicy를 S3ReadOnlyRole에 연결 |
| `aws_iam_user` | `example_user` (기본값) | 역할 위임 테스트를 위한 IAM 사용자 |
| `aws_iam_access_key` | example_user_key | CLI에서 역할 위임 테스트에 사용할 자격증명 |

## 사전 요구사항

- AWS CLI 설정 (`my-profile` 프로파일)
- Terraform >= 1.13.4

## 사용 방법

```bash
cd 07_aws-access-control-and-secret-management/policy-management-using-terraform
terraform init
terraform plan
terraform apply
```

### 역할 위임(AssumeRole) 테스트

apply 완료 후 출력된 자격증명으로 AWS CLI 프로파일을 구성하고, 아래 명령으로 역할을 위임받을 수 있습니다.

```bash
# 출력된 Access Key로 임시 프로파일 설정
aws configure --profile example-user

# 역할 위임 테스트 (출력된 s3_read_role_arn 사용)
aws sts assume-role \
  --role-arn <s3_read_role_arn 출력값> \
  --role-session-name test-session \
  --profile example-user
```

### 주요 출력값

- `user_name`: 생성된 IAM 사용자의 이름
- `s3_read_role_arn`: 역할 위임 테스트 시 사용할 IAM 역할의 ARN
- `user_access_key_id`: AWS CLI 설정에 사용할 Access Key ID
- `user_secret_access_key`: Secret Access Key (민감 정보, `terraform output -raw user_secret_access_key`로 조회)

## 정리

```bash
terraform destroy
```

## 참고사항

- `s3-readonly-policy.json` 파일에 S3 읽기 전용 정책이 정의되어 있으며, `var.s3_policy_file` 변수로 경로를 변경할 수 있습니다.
- 신뢰 정책(Trust Policy)은 `example_user`의 ARN만 역할을 위임받을 수 있도록 제한되어 있습니다. 계정 ID는 `data "aws_caller_identity"`를 통해 동적으로 참조됩니다.
- Secret Access Key는 Terraform 적용 직후에만 조회 가능합니다. `terraform output -raw user_secret_access_key` 명령으로 확인하세요.
