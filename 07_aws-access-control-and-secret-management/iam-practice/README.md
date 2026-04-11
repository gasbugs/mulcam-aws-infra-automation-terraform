# IAM 종합 실습 (iam-practice)

## 개요

IAM의 핵심 개념인 "사용자 직접 정책 연결"과 "역할 위임(AssumeRole)" 두 가지 패턴을 한 프로젝트에서 비교하며 실습하는 종합 프로젝트입니다. 첫 번째 시나리오에서는 개발팀 멤버(`project_member`)에게 S3 읽기/쓰기 정책을 직접 연결하고, 두 번째 시나리오에서는 운영 사용자(`operating_user`)가 EC2 상태 조회 역할을 위임받는 구조를 구현합니다. 두 방식의 차이를 직접 비교하여 IAM 최소 권한 원칙과 역할 기반 접근 제어를 이해할 수 있습니다.

## 학습 목표

- 사용자에게 정책을 직접 연결(`aws_iam_user_policy_attachment`)하는 방식과 역할 위임 방식의 차이를 이해한다
- `jsonencode()`를 사용하여 Terraform 코드 내에서 IAM 정책을 인라인으로 정의하는 방법을 학습한다
- IAM 역할의 신뢰 정책(Trust Policy)에서 특정 IAM 사용자 ARN을 Principal로 지정하는 방법을 익힌다
- EC2 `DescribeInstances`처럼 특정 액션만 허용하는 최소 권한(Least Privilege) 정책을 작성하는 방법을 배운다
- 동일 Terraform 파일 내에서 두 개의 독립적인 IAM 시나리오를 구성하는 코드 패턴을 이해한다

## 생성되는 AWS 리소스

| 리소스 | 이름 | 설명 |
|--------|------|------|
| `aws_iam_policy` | S3ReadWritePolicy | S3 버킷 객체 읽기(`GetObject`) 및 쓰기(`PutObject`) 허용 정책 |
| `aws_iam_user` | project_member | S3 정책을 직접 연결받는 개발팀 멤버 사용자 |
| `aws_iam_user_policy_attachment` | — | project_member에 S3ReadWritePolicy를 직접 연결 |
| `aws_iam_access_key` | example_user_key | project_member의 CLI 접근 자격증명 |
| `aws_iam_user` | operating_user | AssumeRole을 통해 EC2 조회 권한을 획득할 운영 사용자 |
| `aws_iam_role` | DevEC2StatusViewer | operating_user가 위임받을 수 있는 EC2 상태 조회 역할 |
| `aws_iam_policy` | EC2DescribeInstancesPolicy | `ec2:DescribeInstances` 액션만 허용하는 최소 권한 정책 |
| `aws_iam_role_policy_attachment` | — | DevEC2StatusViewer 역할에 EC2DescribeInstancesPolicy 연결 |

## 사전 요구사항

- AWS CLI 설정 (`my-profile` 프로파일)
- Terraform >= 1.13.4

## 사용 방법

```bash
cd 07_aws-access-control-and-secret-management/iam-practice
terraform init
terraform plan
terraform apply
```

### 역할 위임(AssumeRole) 테스트 — 시나리오 2

apply 완료 후 `operating_user`의 자격증명으로 AWS CLI 프로파일을 구성하고 아래와 같이 역할 위임을 테스트할 수 있습니다.

```bash
# operating_user 자격증명으로 프로파일 설정
aws configure --profile operating-user

# DevEC2StatusViewer 역할 위임 요청
aws sts assume-role \
  --role-arn arn:aws:iam::<계정ID>:role/DevEC2StatusViewer \
  --role-session-name ops-session \
  --profile operating-user

# 위임받은 임시 자격증명으로 EC2 인스턴스 목록 조회
aws ec2 describe-instances --region us-east-1
```

### 주요 출력값

- `user_name`: 생성된 IAM 프로젝트 멤버 사용자 이름 (`project_member`)
- `s3_project_data_rw_arn`: S3 읽기/쓰기 정책의 ARN
- `user_access_key_id`: project_member의 Access Key ID
- `user_secret_access_key`: Secret Access Key (민감 정보, `terraform output -raw user_secret_access_key`로 조회)

## 정리

```bash
terraform destroy
```

## 참고사항

- 이 프로젝트는 두 개의 독립적인 시나리오(1번: 직접 정책 연결, 2번: 역할 위임)로 구성되어 있으며, `main.tf` 내 구분선(`#####`)으로 섹션이 나뉩니다.
- S3 정책의 대상 버킷은 `arn:aws:s3:::project-data-bucket/*`으로 고정되어 있습니다. 실제 버킷 이름에 맞게 수정하여 사용하세요.
- EC2 상태 조회 정책은 `Resource = "*"`으로 설정되어 있어 모든 리전의 EC2 인스턴스 조회가 가능합니다. 운영 환경에서는 특정 리소스 ARN으로 범위를 제한하는 것을 권장합니다.
- Secret Access Key는 Terraform 적용 직후에만 조회 가능합니다. `terraform output -raw user_secret_access_key` 명령으로 확인하세요.
