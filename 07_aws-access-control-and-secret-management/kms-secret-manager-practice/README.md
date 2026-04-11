# KMS + Secrets Manager + Aurora 통합 실습

## 개요

KMS 고객 관리형 키(CMK), AWS Secrets Manager, Aurora MySQL을 Terraform으로 통합 구성하는 실습입니다. Aurora DB의 마스터 비밀번호를 Secrets Manager가 자동 관리하도록 설정하고, VPC 안에 배치된 EC2 인스턴스가 IAM 역할을 통해 시크릿을 조회하여 DB에 접속하는 전체 흐름을 구축합니다. 07 모듈에서 가장 복잡한 통합 실습입니다.

## 학습 목표

- KMS 키 정책(Key Policy)을 직접 작성하여 EC2 역할과 Secrets Manager 서비스에 복호화 권한을 부여하는 방법 이해
- Aurora MySQL의 `manage_master_user_password` 옵션으로 비밀번호를 Secrets Manager에 위임하는 방법 습득
- VPC, 퍼블릭/프라이빗/DB 전용 서브넷을 `terraform-aws-modules/vpc` 모듈로 구성하는 방법 이해
- EC2 IAM 인스턴스 프로파일로 자격증명 없이 Secrets Manager에 접근하는 방법 습득
- Terraform 출력값으로 SSH 접속 명령, 시크릿 조회 명령, MySQL 접속 명령을 자동 생성하는 방법 이해

## 생성되는 AWS 리소스

| 리소스 | 이름 | 설명 |
|--------|------|------|
| `module.vpc` | `example-vpc` | 퍼블릭·프라이빗·DB 전용 서브넷을 포함하는 VPC |
| `aws_kms_key` | `example_key` | Aurora 스토리지와 Secrets Manager 시크릿을 암호화하는 CMK |
| `aws_kms_alias` | `{env}-aurora-encryption-key` | KMS 키 별칭 |
| `aws_security_group` | `rds-security-group` | Aurora MySQL 포트(3306) 접근 제어용 보안 그룹 |
| `aws_security_group` | `ssh-access-sg` | EC2 SSH 접속(22번 포트) 허용 보안 그룹 |
| `aws_db_subnet_group` | `{vpc_name}-db-subnet-group-0` | Aurora가 사용할 DB 전용 서브넷 그룹 |
| `aws_rds_cluster` | `{cluster_identifier}-0` | Secrets Manager 자동 비밀번호 관리가 활성화된 Aurora MySQL 클러스터 |
| `aws_rds_cluster_instance` | `My-Aurora-Instance1` | Aurora 클러스터의 컴퓨팅 인스턴스 (기본 1개) |
| `aws_instance` | `{env}-secrets-demo-ec2` | Secrets Manager에서 DB 비밀번호를 조회하는 실습용 EC2 (AL2023) |
| `aws_key_pair` | `ec2-key-{랜덤}` | EC2 SSH 접속용 키페어 |
| `aws_iam_role` | `{env}-ec2-secrets-role` | EC2에 부여하는 Secrets Manager 접근 IAM 역할 |
| `aws_iam_instance_profile` | `{env}-ec2-secrets-profile` | IAM 역할을 EC2에 연결하는 인스턴스 프로파일 |
| `aws_iam_policy` | `{env}-ec2-secrets-policy` | Aurora 시크릿 ARN에 대한 최소 권한 읽기 정책 |

## 사전 요구사항

- AWS CLI 설정 (`my-profile` 프로파일)
- Terraform >= 1.13.4
- 다음 변수는 기본값이 없으므로 반드시 직접 지정 필요:
  - `cluster_identifier`: Aurora 클러스터 이름 (예: `my-aurora-cluster`)
  - `db_username`: Aurora 관리자 계정 이름 (예: `admin`)
  - `allowed_cidr`: Aurora에 접근 허용할 CIDR (예: `10.0.0.0/16`)

## 사용 방법

```bash
terraform init
terraform plan
terraform apply
```

변수를 명령줄에서 직접 지정하는 예시입니다.

```bash
terraform apply \
  -var="cluster_identifier=my-aurora-cluster" \
  -var="db_username=admin" \
  -var="allowed_cidr=10.0.0.0/16"
```

### 주요 출력값

- `ec2_public_ip`: EC2 인스턴스의 공인 IP 주소
- `c01_ec2_ssh_command`: EC2에 SSH로 접속하는 완성된 명령어
- `c02_get_database_password`: AWS CLI로 Aurora 비밀번호를 조회하는 명령어
- `c03_connect_mysql`: Aurora MySQL에 접속하는 명령어
- `private_key_pem`: EC2 SSH 접속용 프라이빗 키 (민감 정보 — `terraform output -raw private_key_pem`으로 확인)

## 정리

```bash
terraform destroy
```

## 참고사항

- Aurora 클러스터 생성에는 약 10~15분이 소요됩니다. `apply` 완료 후 출력값을 통해 각 단계를 순서대로 실습하세요.
- EC2에서 `c02_get_database_password` 출력 명령을 실행하면 Secrets Manager에서 JSON 형식의 비밀번호를 확인할 수 있습니다.
- KMS 키 정책에서 EC2 IAM 역할에 `kms:Decrypt`, `kms:GenerateDataKey` 권한을, Secrets Manager 서비스에 `kms:CreateGrant` 등 시크릿 생성·복호화 권한을 명시적으로 부여합니다.
- `db.r5.large` 인스턴스 클래스는 비용이 발생하므로, 실습 완료 후 반드시 `terraform destroy`로 리소스를 삭제하세요.
- EC2 SSH 보안 그룹은 학습 편의를 위해 전체 IP(`0.0.0.0/0`)를 허용합니다. 실제 운영 환경에서는 접속할 IP 대역으로 제한하세요.
