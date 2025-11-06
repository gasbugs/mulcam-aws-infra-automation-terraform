###########################################
# VPC 및 서브넷 구성 (VPC와 서브넷을 생성)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0" # 최신 버전 사용

  name = "ecs-vpc"     # VPC 이름 설정
  cidr = "10.0.0.0/16" # VPC의 CIDR 블록 설정

  # 가용 영역(azs) 및 퍼블릭/프라이빗 서브넷 설정
  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  enable_nat_gateway = true # NAT 게이트웨이 활성화
  single_nat_gateway = true # 단일 NAT 게이트웨이 사용

  tags = {
    Name = "ecs-vpc" # 리소스에 태그 부여
  }
}

###########################################
# ECS 클러스터 구성 (프라이빗 서브넷에 위치)
resource "aws_ecs_cluster" "ecs_cluster" {
  name = "my-ecs-cluster" # ECS 클러스터 이름
}

# ECS 태스크 실행을 위한 IAM 역할 (ECR 이미지를 접근할 수 있는 권한 부여)
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecs_task_execution_role" # IAM 역할 이름

  # 역할을 부여하기 위한 정책 (ECS 태스크에 권한 부여)
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "ecs-tasks.amazonaws.com" # ECS 태스크에 적용
      }
    }]
  })

  tags = {
    Name = "ECS Task Execution Role" # 역할에 태그 부여
  }
}

# IAM 역할에 AmazonECSTaskExecutionRolePolicy 정책 연결 (ECR 접근 권한 부여)
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name                               # 역할 이름 참조
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" # ECS 실행에 필요한 정책
}

# ECS 태스크 정의 (컨테이너 사양 및 네트워크 모드 설정)
resource "aws_ecs_task_definition" "ecs_task" {
  family                   = "my-ecs-task" # 태스크 패밀리 이름
  network_mode             = "awsvpc"      # 네트워크 모드 설정
  requires_compatibilities = ["FARGATE"]   # Fargate 사용
  cpu                      = "256"         # CPU 리소스 설정 (.25 vCPU)
  memory                   = "512"         # 메모리 설정 (512MB)

  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn # 실행 역할 ARN 설정

  # 컨테이너 정의 (컨테이너 사양 및 포트 매핑 설정)
  container_definitions = <<DEFINITION
  [
    {
      "name": "my-container", 
      "image": "${var.my_repository_url}", 
      "cpu": 256, 
      "memory": 512, 
      "essential": true,
      "portMappings": [
        {
          "containerPort": 80,
          "hostPort": 80  
        }
      ]
    }
  ]
  DEFINITION
}

# ECS 서비스 구성 (로드 밸런서를 통해 서비스 연결)
resource "aws_ecs_service" "ecs_service" {
  name            = "my-ecs-service"                     # 서비스 이름
  cluster         = aws_ecs_cluster.ecs_cluster.id       # ECS 클러스터 참조
  task_definition = aws_ecs_task_definition.ecs_task.arn # 태스크 정의 참조
  launch_type     = "FARGATE"                            # Fargate 런치 타입

  desired_count = 1 # 실행할 태스크 수

  # 네트워크 구성 (프라이빗 서브넷과 보안 그룹 설정)
  network_configuration {
    subnets          = module.vpc.private_subnets     # 프라이빗 서브넷 사용
    security_groups  = [aws_security_group.ecs_sg.id] # 보안 그룹 설정
    assign_public_ip = false                          # 퍼블릭 IP 할당 안 함
  }

  # 로드 밸런서 설정 (ALB와 연결)
  load_balancer {
    target_group_arn = aws_lb_target_group.ecs_tg.arn # 타겟 그룹 참조
    container_name   = "my-container"                 # 컨테이너 이름
    container_port   = 80                             # 컨테이너 포트 설정
  }

  depends_on = [aws_lb_listener.http_listener] # ALB 리스너가 먼저 생성되어야 함
}

###########################################
# ALB 구성 (애플리케이션 로드 밸런서 설정)
resource "aws_lb" "alb" {
  name               = "my-alb"                       # ALB 이름
  internal           = false                          # 외부에 노출되는 ALB
  load_balancer_type = "application"                  # ALB 타입 설정
  security_groups    = [aws_security_group.alb_sg.id] # ALB 보안 그룹
  subnets            = module.vpc.public_subnets      # 퍼블릭 서브넷 사용

  enable_deletion_protection = false # 삭제 보호 기능 비활성화
}

# ALB 타겟 그룹 구성 (ECS 서비스 연결)
resource "aws_lb_target_group" "ecs_tg" {
  name     = "ecs-tg"          # 타겟 그룹 이름
  port     = 80                # 외부에서 접근하는 포트
  protocol = "HTTP"            # HTTP 프로토콜 사용
  vpc_id   = module.vpc.vpc_id # VPC 참조

  target_type = "ip" # 타겟 타입 설정 (IP 기반)

  # 헬스 체크 설정 (서비스 상태 확인)
  health_check {
    path                = "/" # 헬스 체크 경로
    interval            = 30  # 헬스 체크 간격 (초)
    timeout             = 5   # 헬스 체크 타임아웃 (초)
    healthy_threshold   = 2   # 헬스 체크 성공 임계값
    unhealthy_threshold = 2   # 헬스 체크 실패 임계값
  }
}

# ALB 리스너 구성 (HTTP 요청을 타겟 그룹으로 포워딩)
resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.alb.arn # ALB 참조
  port              = "80"           # 외부에서 들어오는 포트
  protocol          = "HTTP"         # HTTP 프로토콜 사용

  default_action {
    type             = "forward"                      # 타겟 그룹으로 요청 포워딩
    target_group_arn = aws_lb_target_group.ecs_tg.arn # 타겟 그룹 참조
  }
}

# ALB 보안 그룹 (외부에서 80번 포트 접근 허용)
resource "aws_security_group" "alb_sg" {
  name   = "alb-sg"          # 보안 그룹 이름
  vpc_id = module.vpc.vpc_id # VPC 참조

  ingress {
    from_port   = 80 # 80번 포트로 접근 허용
    to_port     = 80
    protocol    = "tcp"         # TCP 프로토콜 사용
    cidr_blocks = ["0.0.0.0/0"] # 모든 IP 허용
  }

  egress {
    from_port   = 0 # 모든 포트로 나가는 트래픽 허용
    to_port     = 0
    protocol    = "-1"          # 모든 프로토콜 허용
    cidr_blocks = ["0.0.0.0/0"] # 모든 IP로 허용
  }
}

# ECS 보안 그룹 (80번 포트로 접근 허용)
resource "aws_security_group" "ecs_sg" {
  name   = "ecs-sg"          # 보안 그룹 이름
  vpc_id = module.vpc.vpc_id # VPC 참조

  ingress {
    from_port   = 80 # 80번 포트로 접근 허용
    to_port     = 80
    protocol    = "tcp"           # TCP 프로토콜 사용
    cidr_blocks = ["10.0.0.0/16"] # VPC 내부 IP 대역 허용
  }

  egress {
    from_port   = 0 # 모든 포트로 나가는 트래픽 허용
    to_port     = 0
    protocol    = "-1"          # 모든 프로토콜 허용
    cidr_blocks = ["0.0.0.0/0"] # 모든 IP로 허용
  }
}
