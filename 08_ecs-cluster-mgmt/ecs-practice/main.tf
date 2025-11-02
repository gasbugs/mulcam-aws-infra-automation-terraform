###########################################
# VPC 및 서브넷 구성 (VPC와 서브넷을 생성)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name = "ecs-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.3.0/24", "10.0.4.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Name = "ecs-vpc"
  }
}


###########################################
# ECS 클러스터 구성 (프라이빗 서브넷에 위치)
resource "aws_ecs_cluster" "ecs_cluster" {
  name = "my-ecs-cluster"
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

resource "aws_ecs_task_definition" "ecs_task" {
  family                   = "my-ecs-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = "256"
  memory                   = "512"

  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = <<DEFINITION
  [
    {
      "name": "nginx-container",
      "image": "nginx:latest",
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
  name            = "my-ecs-service"
  cluster         = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.ecs_task.arn
  launch_type     = "EC2"

  desired_count = 1

  network_configuration {
    subnets         = module.vpc.public_subnets
    security_groups = [aws_security_group.ecs_sg.id]
    # assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ecs_tg.arn
    container_name   = "nginx-container"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.http_listener]
}


###########################################
# ALB 구성 (애플리케이션 로드 밸런서 설정)
resource "aws_lb" "alb" {
  name               = "my-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = false
}

resource "aws_lb_target_group" "ecs_tg" {
  name        = "ecs-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ecs_tg.arn
  }
}


# ALB 보안 그룹 (외부에서 80번 포트 접근 허용)
resource "aws_security_group" "alb_sg" {
  name   = "alb-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# ECS 보안 그룹 (8080번 포트로 접근 허용)
resource "aws_security_group" "ecs_sg" {
  name   = "ecs-sg"          # 보안 그룹 이름
  vpc_id = module.vpc.vpc_id # VPC 참조

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp" # TCP 프로토콜 사용
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0 # 모든 포트로 나가는 트래픽 허용
    to_port     = 0
    protocol    = "-1"          # 모든 프로토콜 허용
    cidr_blocks = ["0.0.0.0/0"] # 모든 IP로 허용
  }
}


############################################
# ECS 최적화 Amazon Linux 2023 AMI
data "aws_ami" "ecs_optimized_al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-ecs-hvm-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}


# Launch Template 생성
resource "aws_launch_template" "ecs_lt" {
  name_prefix   = "ecs-launch-template"
  image_id      = data.aws_ami.ecs_optimized_al2023.id # ECS-optimized AMI ID
  instance_type = "t3.micro"

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_agent.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ecs_sg.id]
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              echo ECS_CLUSTER=${aws_ecs_cluster.ecs_cluster.name} >> /etc/ecs/ecs.config
              EOF
  )
}


# Auto Scaling Group 생성
resource "aws_autoscaling_group" "ecs_asg" {
  vpc_zone_identifier = module.vpc.public_subnets
  desired_capacity    = 1
  max_size            = 1
  min_size            = 1

  launch_template {
    id      = aws_launch_template.ecs_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }
}

# ECS Capacity Provider 생성
resource "aws_ecs_capacity_provider" "ecs_cp" {
  name = "my-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.ecs_asg.arn

    managed_scaling {
      maximum_scaling_step_size = 1000
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 100
    }
  }
}


# ECS 클러스터에 Capacity Provider 연결
resource "aws_ecs_cluster_capacity_providers" "example" {
  cluster_name = aws_ecs_cluster.ecs_cluster.name

  capacity_providers = [aws_ecs_capacity_provider.ecs_cp.name]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = aws_ecs_capacity_provider.ecs_cp.name
  }
}

# ECS 인스턴스 역할 생성
resource "aws_iam_role" "ecs_instance_role" {
  name = "ecs_instance_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# ECS 인스턴스 역할에 정책 연결
resource "aws_iam_role_policy_attachment" "ecs_instance_role_attachment" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# IAM 인스턴스 프로파일 생성
resource "aws_iam_instance_profile" "ecs_agent" {
  name = "ecs-agent"
  role = aws_iam_role.ecs_instance_role.name
}
