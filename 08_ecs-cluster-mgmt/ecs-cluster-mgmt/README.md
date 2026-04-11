# ECS Cluster Management Practice

이 프로젝트는 Fargate 기반 ECS 서비스를 ALB 뒤에 배포하는 실습입니다. 실습의 목표는 VPC, ECS, ALB를 만드는 것에 그치지 않고, 실제로 서비스가 정상 배포되고 외부 요청에 응답하며 로그까지 확인하는 것입니다.

## 실습 목표

- 실습용 VPC와 퍼블릭/프라이빗 서브넷을 생성한다.
- ECS 클러스터와 Fargate 서비스를 생성한다.
- ALB를 통해 외부에서 서비스에 접근한다.
- CloudWatch Logs에서 컨테이너 로그를 확인한다.
- 컨테이너 이미지를 변경하고 재배포해 서비스 변경이 반영되는지 확인한다.

## 생성 리소스 정리

- `module.vpc`
  퍼블릭/프라이빗 서브넷과 NAT Gateway를 포함한 실습용 VPC입니다.
- `aws_ecs_cluster.main`
  Fargate 서비스를 실행할 ECS 클러스터입니다.
- `aws_iam_role.ecs_task_execution`
  태스크가 이미지 pull과 로그 전송을 수행할 실행 역할입니다.
- `aws_cloudwatch_log_group.main`
  애플리케이션 컨테이너 로그를 저장하는 로그 그룹입니다.
- `aws_security_group.alb`
  인터넷에서 ALB의 80 포트로 들어오는 요청을 허용합니다.
- `aws_security_group.ecs_service`
  ALB에서 ECS 태스크로 들어가는 트래픽만 허용합니다.
- `aws_lb.main`
  외부 트래픽을 받는 Application Load Balancer입니다.
- `aws_lb_target_group.main`
  ECS 태스크를 대상으로 하는 타깃 그룹입니다.
- `aws_lb_listener.http`
  ALB 80 포트 요청을 타깃 그룹으로 전달합니다.
- `aws_ecs_task_definition.main`
  컨테이너 이미지, 포트, CPU/메모리, 로그 구성을 정의합니다.
- `aws_ecs_service.main`
  실제로 동작하는 Fargate 서비스입니다. 태스크는 프라이빗 서브넷에서 실행되고, 외부 통신은 NAT Gateway를 사용합니다.

## 사전 준비

- AWS CLI에 `my-profile` 프로파일이 설정되어 있어야 합니다.
- 로컬에 `terraform`, `aws`, `curl` 명령이 있어야 합니다.
- 기본값은 공개 NGINX 이미지를 사용하므로 별도 ECR 준비 없이 바로 실습할 수 있습니다.

## 권장 변수 예시

기본 실습 예시 파일로 [`terraform.tfvars.example`](/Users/gasbugs/mulcam-aws-infra-automation-terraform/08_ecs-cluster-mgmt/ecs-cluster-mgmt/terraform.tfvars.example)를 추가해두었습니다. 이를 복사해 로컬 `terraform.tfvars`를 만든 뒤 필요하면 값을 조정합니다.

```hcl
aws_region        = "us-east-1"
project_name      = "ecs-cluster-mgmt"
container_name    = "web"
container_image   = "public.ecr.aws/nginx/nginx:stable-alpine"
container_port    = 80
health_check_path = "/"
desired_count     = 1
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
terraform output ecs_service_name
terraform output alb_dns_name
```

5. 이 프로젝트는 Fargate 태스크가 프라이빗 서브넷에서 NAT Gateway를 통해 외부 이미지를 pull합니다. 따라서 `terraform apply` 직후에는 서비스가 아직 `pending` 상태일 수 있고, ALB가 잠시 `503`을 반환할 수 있습니다. 보통 1분 내외 대기 후 다시 확인하는 것이 안전합니다.

## 동작 검증 절차

### 1. ECS 클러스터와 서비스 생성 확인

```bash
aws ecs describe-clusters \
  --profile my-profile \
  --region us-east-1 \
  --clusters $(terraform output -raw ecs_cluster_name)
```

```bash
aws ecs describe-services \
  --profile my-profile \
  --region us-east-1 \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --services $(terraform output -raw ecs_service_name)
```

확인 포인트:

- `status`가 `ACTIVE`
- `desiredCount`와 `runningCount`가 동일
- 서비스 이벤트에 반복적인 배포 실패 메시지가 없음
- 배포 직후 `runningCount = 0`, `pendingCount = 1`일 수 있으므로 바로 실패로 판단하지 말고 30~60초 정도 기다린 뒤 다시 조회
- 이벤트에 `has reached a steady state` 또는 `deployment completed`가 보이면 다음 검증으로 진행

대기 후 재확인 예시:

```bash
sleep 40
aws ecs describe-services \
  --profile my-profile \
  --region us-east-1 \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --services $(terraform output -raw ecs_service_name)
```

### 2. ALB DNS로 서비스 응답 확인

```bash
curl -I http://$(terraform output -raw alb_dns_name)
```

또는 본문 확인:

```bash
curl http://$(terraform output -raw alb_dns_name)
```

정상이라면 `HTTP/1.1 200 OK`가 반환되거나 NGINX 기본 페이지 HTML이 응답됩니다.

배포 직후 `503 Service Temporarily Unavailable`가 나올 수 있습니다. 이 경우 대개 타깃 등록 또는 헬스체크가 아직 끝나지 않은 상태이므로, ECS 서비스가 steady state가 된 뒤 다시 확인합니다.

### 3. Target Group Healthy 상태 확인

ALB 뒤의 태스크가 실제로 health check를 통과했는지 확인합니다.

```bash
aws elbv2 describe-target-groups \
  --profile my-profile \
  --region us-east-1 \
  --load-balancer-arn $(aws elbv2 describe-load-balancers \
    --profile my-profile \
    --region us-east-1 \
    --query "LoadBalancers[?DNSName=='$(terraform output -raw alb_dns_name)'].LoadBalancerArn" \
    --output text)
```

그 다음 타깃 헬스를 확인합니다.

```bash
aws elbv2 describe-target-health \
  --profile my-profile \
  --region us-east-1 \
  --target-group-arn TARGET_GROUP_ARN
```

확인 포인트:

- 각 타깃의 `TargetHealth.State`가 `healthy`
- 최초 배포 직후에는 `initial` 또는 미등록 상태일 수 있으므로, 잠시 기다린 뒤 재확인

### 4. ECS 태스크 상태 확인

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

- 태스크 `lastStatus`가 `RUNNING`
- 컨테이너 `healthStatus` 또는 상태가 정상
- `PENDING` 상태가 잠시 보일 수 있으며, private subnet + NAT 환경에서는 이미지 pull 시간까지 포함해 초기 기동이 조금 더 걸릴 수 있음

### 5. CloudWatch 로그 확인

로그 그룹이 실제로 생성되고 컨테이너 로그가 들어오는지 확인합니다.

```bash
aws logs describe-log-streams \
  --profile my-profile \
  --region us-east-1 \
  --log-group-name /ecs/ecs-cluster-mgmt
```

```bash
aws logs get-log-events \
  --profile my-profile \
  --region us-east-1 \
  --log-group-name /ecs/ecs-cluster-mgmt \
  --log-stream-name LOG_STREAM_NAME
```

확인 포인트:

- 로그 스트림이 존재한다.
- NGINX 시작 로그 또는 접근 로그가 보인다.

### 6. 이미지 교체 후 재배포 확인

실습자는 `container_image`를 자신이 만든 ECR 이미지 또는 다른 공개 이미지로 바꿔 재배포할 수 있습니다.

예시:

```hcl
container_image = "public.ecr.aws/nginx/nginx:mainline-alpine"
```

변경 후 다시 실행합니다.

```bash
terraform apply
```

이후 아래를 확인합니다.

```bash
aws ecs describe-services \
  --profile my-profile \
  --region us-east-1 \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --services $(terraform output -raw ecs_service_name)
```

확인 포인트:

- 새 deployment가 완료되었는지
- `runningCount`가 `desiredCount`와 같은지
- ALB 응답이 계속 정상인지

## 전체 검증 체크리스트

- `terraform apply`가 성공했다.
- ECS 클러스터와 서비스가 `ACTIVE` 상태다.
- 실행 중 태스크 수가 원하는 수와 일치한다.
- ALB DNS로 HTTP 200 응답을 받는다.
- Target Group 상태가 `healthy`다.
- CloudWatch Logs에 컨테이너 로그가 쌓인다.
- 컨테이너 이미지를 변경한 뒤 재배포해도 서비스가 정상 동작한다.

## 정리

```bash
terraform destroy
```

## 참고

- 이 프로젝트는 Fargate 예제이므로 EC2 Capacity Provider 없이 서비스 배포 흐름에 집중합니다.
- VPC AZ는 현재 리전의 사용 가능한 AZ를 조회해 앞의 두 개를 사용합니다.
- 현재 구성은 모범사례에 맞춰 `ALB는 public subnet`, `Fargate 태스크는 private subnet`, `외부 통신은 NAT Gateway` 구조를 사용합니다.
- 이 구조에서는 `terraform apply` 직후 즉시 ALB를 확인하면 일시적으로 `503`이 보일 수 있습니다. 실제 검증은 ECS 서비스 steady state와 Target Group healthy 상태를 먼저 확인한 뒤 진행하는 것이 맞습니다.
- 다음 단계에서는 `ecs-practice` README를 같은 방식으로, EC2 인스턴스 등록, Capacity Provider, ECS on EC2 태스크 실행 확인까지 포함해 정리하면 됩니다.
