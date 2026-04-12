# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

A structured learning repository for AWS infrastructure automation with Terraform, organized as 11 progressive modules (01–11) covering topics from HCL fundamentals to EKS with CI/CD. The repository contains ~65 self-contained Terraform projects across ~400 `.tf` files.

## Standard Terraform Workflow

Each project directory is self-contained. Navigate into the target project directory before running commands:

```bash
cd <module-dir>/<project-dir>
terraform init
terraform plan
terraform apply
terraform destroy   # Always destroy after use — resources incur AWS costs
```

## Provider Configuration

All projects use:
- **Terraform:** `>= 1.13.4`
- **AWS Provider:** `~> 6.0`
- **AWS CLI profile:** `my-profile` (named profile in `~/.aws/config`)

Advanced modules (EKS) also use Helm (`>= 2.7`), kubectl/alekc (`>= 2.0`), and Kubernetes providers.

## Packer AMI Builds

Packer templates (`.pkr.hcl`) live inside module directories:

```bash
packer init <template>.pkr.hcl
packer build <template>.pkr.hcl
```

The Java Spring Boot example (`05_elb-asg-terraform/packer-for-javaspring/`) has a full Docker→Packer pipeline:

```bash
./build_and_pack.sh   # Docker build + Packer AMI bake
```

## Architecture Overview

### Module Progression

| # | Module | Core Topics |
|---|--------|-------------|
| 01 | aws-terraform-overview | EC2 basics, provider setup |
| 02 | HCL | Variables, loops, modules, blocks |
| 03 | terraform-aws-config | VPC, EC2, remote state (S3 backend) |
| 04 | aws-serverless | Lambda, API Gateway, S3, CloudFront, Route53 |
| 05 | elb-asg | ALB, ASG, Packer AMI, SSL termination |
| 06 | db-service | RDS MySQL, Aurora, DynamoDB, ElastiCache Redis |
| 07 | access-control | IAM, KMS, Secrets Manager |
| 08 | ecs-cluster | ECS, ECR, pull-through cache |
| 09 | eks-cluster | EKS, node groups (autoscaler/IRSA/Karpenter/Fargate/Spot) |
| 10 | eks-with-cicd | EKS + CodePipeline, private ECR |
| 11 | practical-project | WordPress on EC2 and EKS (end-to-end) |

### Key Patterns

- **Self-contained projects:** Each subdirectory has its own `provider.tf`, `variables.tf`, `outputs.tf`, and `main.tf`.
- **Custom modules:** Stored in a local `./modules/` subdirectory within a project.
- **Public modules:** Uses `terraform-aws-modules/vpc/aws` (v6.5.0) and similar registry modules.
- **Immutable infrastructure:** Packer bakes AMIs; Terraform deploys them. No in-place EC2 configuration management.
- **Containerized builds:** Spring Boot apps are compiled inside Docker (`maven:3.9.6-eclipse-temurin-17`) before Packer packaging.


## Workshop Management Scripts

All scripts read `accesskey.txt` (tab-separated `access_key` and `secret_key`, one account per line) from the working directory and process accounts in parallel.

| 파일 | 용도 |
|---|---|
| `aws-resource-audit.py` | 잔여 리소스 감사 — 27개 서비스 유형 스캔, [비용주의] 리소스 강조 표시 |
| `aws-workshop-setup.py` | 수강생 계정 셋업 — 정책 생성·사용자 생성·콘솔 접근 설정·CSV 출력 |
| `aws-workshop-teardown.py` | 수강생 IAM 사용자(`terraform-user-1`) 완전 삭제 |
| `aws-daily-cost-report.py` | 전일 비용 리포트 — Cost Explorer로 서비스별 비용 조회 |

## Workshop IAM Policy

`TerraformWorkshop-Restricted-us-east-1.json` at the root defines the IAM policy applied to workshop student accounts, restricting allowed actions to `us-east-1` only. Reference this when troubleshooting permission errors or understanding which services are available.

## Standard Variable Pattern

Most projects declare these common input variables in `variables.tf`:
- `aws_region` — defaults to `"us-east-1"`
- `aws_profile` — defaults to `"my-profile"`
- `environment` — used for resource name prefixes/tags

Override at apply time: `terraform apply -var="aws_region=ap-northeast-2"`
