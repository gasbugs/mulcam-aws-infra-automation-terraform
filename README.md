# AWS Infrastructure Automation with Terraform

이 저장소는 Terraform을 사용하여 AWS 인프라를 자동화하는 다양한 실습 예제와 프로젝트를 포함하고 있습니다.
EC2, VPC, S3, EKS, CI/CD 등 다양한 AWS 서비스와 Terraform의 핵심 개념을 학습할 수 있도록 구성되어 있습니다.

## 목차 (Table of Contents)

1. [AWS Terraform Overview](01_aws-terraform-overview)
2. [HCL (HashiCorp Configuration Language) Basics](02_HCL)
3. [Terraform AWS Config](03_terraform-aws-config)
4. [AWS Serverless Services](04_aws-serverless-services-using-terraform)
5. [ELB & ASG (Elastic Load Balancer & Auto Scaling Group)](05_elb-asg-terraform)
6. [DB Service Management](06_db-service-management)
7. [AWS Access Control & Secret Management](07_aws-access-control-and-secret-management)
8. [ECS Cluster Management](08_ecs-cluster-mgmt)
9. [EKS Cluster Management](09_eks-cluster-mgmt)
10. [EKS with CI/CD](10_eks-with-cicd)
11. [AWS Practical Project](11_aws-practical-project)

## 필수 조건 (Prerequisites)

이 프로젝트를 실행하기 위해서는 다음 도구들이 설치되어 있어야 합니다:

- [Terraform](https://www.terraform.io/downloads.html) (v1.0.0 이상 권장)
- [AWS CLI](https://aws.amazon.com/cli/) (v2 이상 권장)
- AWS 계정 및 적절한 IAM 권한

## 시작하기 (Getting Started)

각 디렉토리에는 해당 실습에 대한 Terraform 코드가 포함되어 있습니다. 실습을 진행하려면 해당 디렉토리로 이동하여 다음 명령어를 실행하세요:

```bash
# 초기화
terraform init

# 계획 확인
terraform plan

# 적용
terraform apply
```

> [!WARNING]
> `terraform apply`를 실행하면 실제 AWS 리소스가 생성되어 비용이 발생할 수 있습니다. 실습이 끝난 후에는 반드시 `terraform destroy`를 실행하여 리소스를 정리하세요.