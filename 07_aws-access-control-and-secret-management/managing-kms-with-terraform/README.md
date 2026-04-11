# managing-kms-with-terraform

## 개요

AWS KMS(Key Management Service)를 Terraform으로 관리하는 실습 프로젝트입니다. 고객 관리형 KMS 키를 생성하고, 해당 키로 S3 버킷 저장 데이터와 EC2 루트 볼륨을 암호화하는 전체 흐름을 자동화합니다. EC2 인스턴스에 IAM 역할(Instance Profile)을 부여하여 키 없이도 암호화된 S3 데이터에 안전하게 접근하는 패턴을 실습합니다.

## 학습 목표

- AWS KMS 고객 관리형 키(CMK) 생성 및 키 정책(Key Policy) 작성 방법 이해
- KMS 키를 활용한 S3 서버 측 암호화(SSE-KMS) 구성 방법 습득
- EC2 루트 볼륨을 KMS로 암호화하는 방법 학습
- IAM 역할(Instance Profile) 기반으로 EC2가 KMS 키를 사용하는 권한 위임 패턴 이해
- TLS 프로바이더를 활용하여 외부 파일 없이 SSH 키페어를 자동 생성하는 방법 학습

## 생성되는 AWS 리소스

| 리소스 | 이름 | 설명 |
|--------|------|------|
| `aws_kms_key` | `<environment>-s3-kms-key` | S3 및 EC2 볼륨 암호화에 사용할 고객 관리형 KMS 키 (90일 자동 교체) |
| `aws_kms_alias` | `alias/<environment>-s3-encryption-key` | KMS 키 ID 대신 사용하는 알기 쉬운 별칭 |
| `aws_s3_bucket` | `<bucket_name>-<random>` | KMS로 암호화되는 데이터 저장 버킷 |
| `aws_s3_bucket_server_side_encryption_configuration` | (버킷에 연결) | 버킷에 저장되는 모든 객체를 KMS로 자동 암호화하는 설정 |
| `aws_s3_bucket_public_access_block` | (버킷에 연결) | 버킷의 퍼블릭 접근을 완전 차단하는 보안 설정 |
| `aws_s3_bucket_versioning` | (버킷에 연결) | 파일 수정·삭제 시 이전 버전을 보존하는 버전 관리 |
| `aws_s3_bucket_ownership_controls` | (버킷에 연결) | 버킷 소유자가 모든 객체를 소유하도록 ACL 비활성화 |
| `aws_iam_role` | `<environment>-ec2-s3-access-role` | EC2가 S3 및 KMS에 접근할 수 있도록 권한을 위임하는 IAM 역할 |
| `aws_iam_policy` | `<environment>-ec2-s3-kms-policy` | S3 GetObject/PutObject 권한을 정의하는 IAM 정책 |
| `aws_iam_role_policy_attachment` | (역할에 연결) | IAM 역할에 정책을 연결 |
| `aws_iam_instance_profile` | `<environment>-ec2-s3-access-profile` | IAM 역할을 EC2에 연결하는 인스턴스 프로파일 |
| `aws_security_group` | `<environment>-ec2-sg` | SSH(22번 포트) 접속을 허용하는 보안 그룹 |
| `tls_private_key` | (로컬 생성) | Terraform이 직접 생성하는 RSA 4096비트 SSH 키페어 |
| `aws_key_pair` | `ec2-key-<random>` | Terraform이 생성한 공개 키를 AWS에 등록한 키페어 |
| `local_file` | `ec2-key.pem` | SSH 접속에 사용할 프라이빗 키 파일 (로컬 저장) |
| `aws_instance` | `<environment>-kms-demo-ec2` | KMS 암호화 볼륨과 IAM 역할이 적용된 실습용 EC2 인스턴스 |

## 사전 요구사항

- AWS CLI 설정 (`my-profile` 프로파일)
- Terraform >= 1.13.4
- KMS 키 정책에서 `user0` IAM 사용자가 참조됩니다. 실습 계정에 해당 사용자가 없다면 `main.tf`의 키 정책에서 계정에 맞게 수정이 필요합니다.
- 기본 VPC가 존재하는 리전(기본값: `us-east-1`)에서 실행해야 합니다.

## 사용 방법

```bash
terraform init
terraform plan
terraform apply
```

### 변수 커스터마이징

기본값을 변경하려면 `terraform apply` 시 변수를 지정합니다.

```bash
terraform apply \
  -var="environment=staging" \
  -var="bucket_name=my-secure-data" \
  -var="aws_region=us-east-1"
```

### EC2 SSH 접속

`terraform apply` 완료 후 출력된 명령어로 바로 접속할 수 있습니다.

```bash
# 출력값 확인
terraform output ec2_ssh_command

# 접속 예시 (ec2-key.pem은 apply 후 자동 생성됨)
ssh -i ec2-key.pem ec2-user@<ec2_public_ip>
```

### 주요 출력값

- `bucket_name`: 생성된 S3 버킷의 이름
- `kms_key_arn`: S3 및 EC2 볼륨 암호화에 사용된 KMS 키의 ARN
- `ec2_instance_id`: 생성된 EC2 인스턴스의 ID
- `ec2_public_ip`: EC2 인스턴스의 공인 IP 주소
- `s3_access_policy_arn`: EC2가 S3에 접근할 수 있도록 허용하는 IAM 정책의 ARN
- `ec2_ssh_command`: EC2에 SSH로 접속하는 완성된 명령어
- `private_key_pem`: EC2 SSH 접속용 프라이빗 키 (민감 정보, `terraform output -raw private_key_pem`으로 조회)

## 정리

```bash
terraform destroy
```

## 참고사항

- **KMS 키 삭제 대기 기간**: `terraform destroy` 실행 시 KMS 키는 즉시 삭제되지 않고, `deletion_window_in_days = 30` 설정에 따라 30일 후 삭제됩니다. 이 기간 동안 키 복구가 가능합니다.
- **SSH 키 자동 생성**: EC2 키페어는 TLS 프로바이더로 자동 생성되며, `ec2-key.pem` 파일이 프로젝트 디렉토리에 저장됩니다. `.gitignore`에 추가하여 실수로 커밋되지 않도록 주의하세요.
- **KMS 키 정책**: `main.tf`의 키 정책에 `user0` IAM 사용자가 하드코딩되어 있습니다. 실습 환경에 맞는 사용자 이름으로 변경 후 사용하세요.
- **KMS 키 자동 교체**: `rotation_period_in_days = 90`으로 90일마다 키가 자동 교체됩니다. 교체된 이후에도 기존 암호화 데이터는 이전 키 버전으로 복호화할 수 있습니다.
- **S3 버킷 이름 고유성**: 버킷 이름에 랜덤 4자리 숫자가 붙어 전역 고유성을 보장합니다.
