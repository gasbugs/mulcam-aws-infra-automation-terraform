# ECS Practice

이 프로젝트는 ECS on EC2 실습입니다. Fargate가 아니라 EC2 인스턴스가 실제 ECS Container Instance로 등록되고, Capacity Provider를 통해 ECS 서비스가 올라가는 흐름까지 확인하는 것이 목적입니다.

## 실습 목표

- ECS 최적화 Amazon Linux 2023 EC2 인스턴스를 Auto Scaling Group으로 생성한다.
- ECS 클러스터에 EC2 Container Instance가 정상 등록되는지 확인한다.
- ECS Capacity Provider와 클러스터 연결 상태를 확인한다.
- ECS 서비스가 EC2 기반으로 태스크를 정상 실행하는지 확인한다.
- ALB를 통해 애플리케이션에 접속한다.
- SSM Session Manager로 컨테이너 인스턴스에 접속해 ECS 에이전트 상태를 확인한다.

## 생성 리소스 정리

- `module.vpc`
  퍼블릭 서브넷 기반 실습용 VPC입니다.
- `aws_ecs_cluster.main`
  ECS on EC2 워크로드를 실행할 클러스터입니다.
- `aws_iam_role.ecs_instance`
  EC2 인스턴스가 ECS 클러스터에 등록되고 SSM 접속이 가능하도록 하는 역할입니다.
- `aws_iam_instance_profile.ecs_agent`
  위 IAM 역할을 EC2 인스턴스에 연결하는 인스턴스 프로파일입니다.
- `aws_launch_template.main`
  ECS 최적화 AL2023 AMI, 인스턴스 타입, user data를 정의합니다.
- `aws_autoscaling_group.main`
  ECS 컨테이너 인스턴스를 실제로 생성하는 Auto Scaling Group입니다.
- `aws_ecs_capacity_provider.main`
  Auto Scaling Group을 ECS와 연결하는 Capacity Provider입니다.
- `aws_ecs_cluster_capacity_providers.main`
  클러스터의 기본 Capacity Provider 전략을 정의합니다.
- `aws_ecs_task_definition.main`
  EC2 launch type용 태스크 정의입니다.
- `aws_ecs_service.main`
  Capacity Provider를 통해 EC2 인스턴스 위에 태스크를 실행하는 서비스입니다.
- `aws_lb.main`, `aws_lb_target_group.main`, `aws_lb_listener.http`
  외부 요청을 받는 ALB 구성입니다.
- `aws_cloudwatch_log_group.main`
  컨테이너 로그를 저장합니다.

## 사전 준비

- AWS CLI에 `my-profile` 프로파일이 설정되어 있어야 합니다.
- 로컬에 `terraform`, `aws`, `curl` 명령이 있어야 합니다.
- SSM 접속 검증까지 하려면 로컬에 Session Manager Plugin이 설치되어 있어야 합니다.
- 기본 컨테이너 이미지는 공개 NGINX 이미지이므로 별도 ECR 준비 없이 시작할 수 있습니다.

## 권장 변수 예시

기본 실습 예시 파일로 [`terraform.tfvars.example`](/Users/gasbugs/mulcam-aws-infra-automation-terraform/08_ecs-cluster-mgmt/ecs-practice/terraform.tfvars.example)를 추가해두었습니다. 필요하면 이를 참고해 [`terraform.tfvars`](/Users/gasbugs/mulcam-aws-infra-automation-terraform/08_ecs-cluster-mgmt/ecs-practice/terraform.tfvars)를 수정합니다.

```hcl
aws_region        = "us-east-1"
project_name      = "ecs-practice"
container_name    = "nginx-container"
container_image   = "public.ecr.aws/nginx/nginx:stable-alpine"
container_port    = 80
desired_count     = 1
ec2_instance_type = "t3.micro"
health_check_path = "/"
```

## 배포 절차

1. 초기화합니다.

```bash
terraform init -upgrade
```

2. 변경 계획을 확인합니다.

```bash
terraform plan
```

3. 리소스를 생성합니다.

```bash
terraform apply
```

4. 출력값을 확인합니다.

```bash
terraform output ecs_cluster_name
terraform output capacity_provider_name
terraform output alb_dns_name
```

## 동작 검증 절차

### 1. ECS 클러스터 생성 확인

```bash
aws ecs describe-clusters \
  --profile my-profile \
  --region us-east-1 \
  --clusters $(terraform output -raw ecs_cluster_name)
```

확인 포인트:

- 클러스터 `status`가 `ACTIVE`

### 2. EC2 Container Instance 등록 확인

Auto Scaling Group이 올린 EC2 인스턴스가 ECS 클러스터에 붙었는지 확인합니다.

```bash
aws ecs list-container-instances \
  --profile my-profile \
  --region us-east-1 \
  --cluster $(terraform output -raw ecs_cluster_name)
```

```bash
aws ecs describe-container-instances \
  --profile my-profile \
  --region us-east-1 \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --container-instances CONTAINER_INSTANCE_ARN
```

확인 포인트:

- 컨테이너 인스턴스가 1개 이상 등록됨
- `status`가 `ACTIVE`
- `agentConnected`가 `true`
- `runningTasksCount`가 1 이상이면 EC2 기반 태스크가 실제로 이 인스턴스에서 실행 중임

### 3. Capacity Provider 연결 확인

```bash
aws ecs describe-capacity-providers \
  --profile my-profile \
  --region us-east-1 \
  --capacity-providers $(terraform output -raw capacity_provider_name)
```

```bash
aws ecs describe-clusters \
  --profile my-profile \
  --region us-east-1 \
  --clusters $(terraform output -raw ecs_cluster_name) \
  --include ATTACHMENTS,SETTINGS,STATISTICS,CONFIGURATIONS,TAGS
```

확인 포인트:

- Capacity Provider 상태가 `ACTIVE`
- 클러스터에 해당 Capacity Provider가 연결되어 있음
- 현재 코드의 기본 Capacity Provider 이름은 `cp-ecs-practice`

### 4. ECS 서비스와 태스크 실행 확인

서비스 이름은 Terraform 코드상 `${project_name}-service` 형식입니다. 기본값이면 `ecs-practice-service`입니다.

```bash
aws ecs describe-services \
  --profile my-profile \
  --region us-east-1 \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --services ecs-practice-service
```

```bash
aws ecs list-tasks \
  --profile my-profile \
  --region us-east-1 \
  --cluster $(terraform output -raw ecs_cluster_name)
```

```bash
aws ecs describe-tasks \
  --profile my-profile \
  --region us-east-1 \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --tasks TASK_ARN
```

확인 포인트:

- 서비스 `status`가 `ACTIVE`
- `runningCount`가 `desiredCount`와 같음
- 태스크 `lastStatus`가 `RUNNING`

### 5. ALB 응답 확인

```bash
curl -I http://$(terraform output -raw alb_dns_name)
```

또는 본문 확인:

```bash
curl http://$(terraform output -raw alb_dns_name)
```

정상이라면 `HTTP/1.1 200 OK` 또는 NGINX 기본 페이지가 반환됩니다.

### 6. Target Group Healthy 상태 확인

먼저 대상 그룹을 찾습니다.

```bash
aws elbv2 describe-target-groups \
  --profile my-profile \
  --region us-east-1
```

그 다음 헬스를 확인합니다.

```bash
aws elbv2 describe-target-health \
  --profile my-profile \
  --region us-east-1 \
  --target-group-arn TARGET_GROUP_ARN
```

확인 포인트:

- 등록된 타깃 상태가 `healthy`

### 7. CloudWatch 로그 확인

```bash
aws logs describe-log-streams \
  --profile my-profile \
  --region us-east-1 \
  --log-group-name /ecs/ecs-practice
```

```bash
aws logs get-log-events \
  --profile my-profile \
  --region us-east-1 \
  --log-group-name /ecs/ecs-practice \
  --log-stream-name LOG_STREAM_NAME
```

확인 포인트:

- 로그 스트림이 생성됨
- 컨테이너 시작 로그나 접근 로그가 보임

### 8. SSM으로 ECS 컨테이너 인스턴스 접속 확인

이 프로젝트는 EC2 인스턴스 역할에 `AmazonSSMManagedInstanceCore`를 부여했으므로 Session Manager로 접속할 수 있어야 합니다.

1. 인스턴스 ID를 찾습니다.

```bash
aws ec2 describe-instances \
  --profile my-profile \
  --region us-east-1 \
  --filters Name=instance-state-name,Values=running \
  --query "Reservations[].Instances[].InstanceId"
```

2. Session Manager로 접속합니다.

```bash
aws ssm start-session \
  --profile my-profile \
  --region us-east-1 \
  --target INSTANCE_ID
```

3. 접속 후 ECS 에이전트 상태를 확인합니다.

```bash
cat /etc/ecs/ecs.config
systemctl status ecs
docker ps
```

확인 포인트:

- `/etc/ecs/ecs.config`에 올바른 클러스터명이 들어 있음
- ECS 에이전트가 active 상태
- 실행 중 컨테이너가 보임
- 실제 검증 예시:
  `ECS_CLUSTER=ecs-practice-cluster`
  `systemctl is-active ecs -> active`
  `docker ps`에 `amazon-ecs-agent`와 `public.ecr.aws/nginx/nginx:stable-alpine`가 표시됨

### 9. 이미지 변경 후 재배포 확인

이미지를 다른 공개 이미지나 ECR 이미지로 바꾼 뒤 재배포합니다.

예시:

```hcl
container_image = "public.ecr.aws/nginx/nginx:mainline-alpine"
```

```bash
terraform apply
```

재배포 후 다시 아래를 확인합니다.

- ECS 서비스 `runningCount == desiredCount`
- ALB 응답 정상
- 로그 스트림 신규 생성 또는 로그 반영

## 전체 검증 체크리스트

- `terraform apply`가 성공했다.
- ECS 클러스터가 `ACTIVE` 상태다.
- EC2 Container Instance가 클러스터에 등록되었다.
- `agentConnected`가 `true`다.
- Capacity Provider가 `ACTIVE` 상태다.
- ECS 서비스와 태스크가 정상 실행 중이다.
- ALB를 통해 HTTP 200 응답을 받는다.
- Target Group 상태가 `healthy`다.
- CloudWatch Logs에 컨테이너 로그가 쌓인다.
- SSM으로 EC2 인스턴스에 접속할 수 있다.
- 인스턴스 내부에서 ECS 에이전트가 정상 동작한다.

## 정리

```bash
terraform destroy
```

- ECS on EC2 서비스는 종료 시 타깃 드레이닝과 서비스 삭제 반영까지 수 분이 걸릴 수 있습니다.
- `desiredCount = 0`으로 내려간 뒤에도 `aws_ecs_service`가 한동안 `DRAINING` 상태로 보일 수 있으니 바로 실패로 판단하지 말고 조금 더 기다립니다.

## 참고

- ECS 최적화 AL2023 AMI는 SSM 공개 파라미터 `/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id`로 조회합니다.
- 이 프로젝트는 ECS on EC2 학습용이므로 Fargate와 달리 인스턴스 등록 상태와 ECS 에이전트 상태를 함께 확인해야 합니다.
