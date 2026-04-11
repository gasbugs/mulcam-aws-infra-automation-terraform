# Managing Secrets Manager with Terraform

## 개요

AWS Secrets Manager를 Terraform으로 구성하고, KMS 고객 관리형 키(CMK)로 시크릿을 암호화하는 방법을 실습합니다. Lambda 함수를 로테이션 핸들러로 등록하여 30일 주기로 비밀번호가 자동 교체되는 전체 파이프라인을 구성합니다.

## 학습 목표

- AWS Secrets Manager에 사용자 이름/비밀번호를 JSON 형식으로 저장하는 방법 이해
- KMS 고객 관리형 키(CMK)를 생성하고 시크릿 암호화에 연결하는 방법 습득
- Lambda 함수를 Secrets Manager 로테이션 핸들러로 등록하는 방법 이해
- Lambda 실행에 필요한 IAM 역할, 정책, 권한(Permission)을 Terraform으로 구성하는 방법 습득
- 자동 로테이션 주기와 Secrets Manager → Lambda 호출 허용 구조 이해

## 생성되는 AWS 리소스

| 리소스 | 이름 | 설명 |
|--------|------|------|
| `aws_kms_key` | `example_key` | 시크릿 데이터를 암호화하는 고객 관리형 KMS 키 |
| `aws_kms_alias` | `{env}-secrets-manager-key` | KMS 키를 식별하기 쉽도록 지정하는 별칭 |
| `aws_secretsmanager_secret` | `my-example-secret-{랜덤}` | 사용자명/비밀번호를 저장하는 시크릿 컨테이너 |
| `aws_secretsmanager_secret_version` | - | 시크릿의 초기 값(사용자명 + 자동 생성 비밀번호) |
| `aws_secretsmanager_secret_rotation` | - | Lambda를 통한 30일 주기 자동 로테이션 설정 |
| `aws_lambda_function` | `rotate-secret-function` | 비밀번호 교체 로직을 수행하는 Python 3.12 함수 |
| `aws_iam_role` | `lambda-secrets-manager-role` | Lambda 실행에 필요한 IAM 역할 |
| `aws_iam_policy` | `lambda-secrets-manager-policy` | Secrets Manager 읽기/쓰기 + CloudWatch 로그 권한 |
| `aws_iam_policy` | `LambdaKMSAccessPolicy` | KMS 암호화/복호화 권한 |
| `aws_lambda_permission` | `AllowSecretsManagerInvocation` | Secrets Manager가 Lambda를 호출하도록 허용 |

## 사전 요구사항

- AWS CLI 설정 (`my-profile` 프로파일)
- Terraform >= 1.13.4
- `lambda/` 디렉토리에 `rotate_secret.py` Python 소스 파일 존재 (ZIP으로 자동 패키징됨)
- `secret_username` 변수는 기본값이 없으므로 반드시 직접 지정 필요

## 사용 방법

```bash
terraform init
terraform plan
terraform apply
```

`secret_username` 변수를 명령줄에서 직접 지정할 수 있습니다.

```bash
terraform apply -var="secret_username=admin"
```

### 주요 출력값

- `secret_arn`: 생성된 Secrets Manager 시크릿의 ARN — `ec2-for-secret-manager` 실습에서 입력값으로 사용
- `lambda_function_name`: 자동 로테이션을 담당하는 Lambda 함수 이름

## 정리

```bash
terraform destroy
```

## 참고사항

- 이 프로젝트에서 출력되는 `secret_arn` 값은 `ec2-for-secret-manager` 실습의 `secret_arn` 입력 변수로 사용됩니다. `terraform output secret_arn` 명령으로 값을 확인하세요.
- KMS 키는 삭제 요청 후 30일 대기 기간이 있습니다. `terraform destroy` 이후에도 키가 즉시 삭제되지 않으며, AWS 콘솔에서 "삭제 예정" 상태로 표시됩니다.
- KMS 키 자동 교체(`enable_key_rotation = true`)는 1년 주기로 동작하며, 기존에 암호화된 데이터는 자동으로 재암호화됩니다.
- Lambda 함수는 `lambda/rotate_secret.py` 파일을 ZIP으로 자동 패키징합니다. 소스 파일 변경 시 `source_code_hash`에 의해 Lambda가 자동으로 업데이트됩니다.
