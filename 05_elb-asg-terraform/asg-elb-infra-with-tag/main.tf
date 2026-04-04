# 여러 리소스에 반복 적용할 공통 태그를 한 곳에서 관리
locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    Owner       = var.owner
  }
}

# 키 페어 이름 충돌 방지를 위한 랜덤 숫자 생성
resource "random_integer" "example" {
  min = 1000
  max = 9999
}

# RSA 알고리즘으로 SSH 키 쌍 자동 생성 (파일 없이 Terraform이 직접 생성)
resource "tls_private_key" "example" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# 생성된 공개 키를 AWS에 등록하여 EC2 인스턴스 SSH 접속에 사용
resource "aws_key_pair" "example" {
  key_name   = "example-keypair-${random_integer.example.result}"
  public_key = tls_private_key.example.public_key_openssh # TLS 리소스에서 공개 키 자동 참조
}

# VPC 모듈 생성 (퍼블릭/프라이빗 서브넷, NAT 게이트웨이 포함)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name                 = "example-vpc"
  cidr                 = var.vpc_cidr
  azs                  = ["${var.aws_region}a", "${var.aws_region}b"] # 가용 영역 2개 설정
  public_subnets       = var.public_subnets                           # 퍼블릭 서브넷 CIDR
  private_subnets      = var.private_subnets                          # 프라이빗 서브넷 CIDR
  enable_dns_hostnames = true                                         # DNS 호스트 이름 활성화
  enable_dns_support   = true                                         # DNS 지원 활성화

  create_igw = true # 인터넷 게이트웨이 자동 생성

  # NAT 게이트웨이 설정 (프라이빗 서브넷 → 인터넷 아웃바운드용)
  enable_nat_gateway = true
  single_nat_gateway = true # 비용 절감을 위해 NAT 게이트웨이 1개만 사용

  public_subnet_tags = {
    Name = "example-public-subnet"
  }

  tags = {
    Name = "example-vpc"
  }
}

# Amazon Linux 2023 최신 AMI ID를 자동으로 조회
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ALB(로드 밸런서)용 보안 그룹 - 인터넷에서 HTTP 트래픽만 허용
resource "aws_security_group" "alb" {
  name_prefix = "example-alb-sg"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow HTTP from internet" # 인터넷에서 오는 HTTP 트래픽 허용
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"           # 모든 프로토콜 허용
    cidr_blocks = ["0.0.0.0/0"] # 모든 아웃바운드 트래픽 허용
  }

  tags = {
    Name = "example-alb-sg"
  }
}

# EC2 인스턴스용 보안 그룹 - ALB에서 오는 트래픽만 허용 (직접 인터넷 접근 차단)
resource "aws_security_group" "ec2" {
  name_prefix = "example-ec2-sg"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Allow HTTP from ALB only" # ALB 보안 그룹에서 오는 HTTP 트래픽만 허용 (직접 인터넷 접근 차단)
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id] # ALB SG에서 오는 트래픽만 허용
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "example-ec2-sg"
  }
}

# EC2 인스턴스 시작 설정 (AMI, 인스턴스 타입, 초기화 스크립트 등 정의)
resource "aws_launch_template" "example" {
  name_prefix   = "example-launch-template"
  image_id      = data.aws_ami.al2023.id # 위에서 조회한 최신 AMI 사용
  instance_type = var.instance_type

  user_data = filebase64("${path.module}/user_data.sh") # 인스턴스 시작 시 실행할 초기화 스크립트

  key_name = aws_key_pair.example.key_name

  # EC2 보안 그룹 연결 (ALB에서 오는 트래픽만 허용)
  network_interfaces {
    security_groups = [aws_security_group.ec2.id]
  }
}

# 오토 스케일링 그룹 - 트래픽에 따라 EC2 인스턴스 수를 자동으로 조절
resource "aws_autoscaling_group" "example" {
  launch_template {
    id      = aws_launch_template.example.id
    version = "$Latest"
  }

  # ALB 상태 확인 방식 사용 (nginx가 실제로 응답하는지 확인 후 비정상 인스턴스 교체)
  health_check_type         = "ELB"
  health_check_grace_period = 300 # 인스턴스 부팅 및 nginx 시작 대기 시간 300초

  vpc_zone_identifier = module.vpc.private_subnets # 프라이빗 서브넷에 인스턴스 배포
  desired_capacity    = var.desired_capacity        # 변수로 관리하여 tfvars에서 조정 가능
  max_size            = var.max_size
  min_size            = var.min_size

  # ALB 타겟 그룹에 직접 연결 (별도 aws_autoscaling_attachment 리소스 불필요)
  target_group_arns = [aws_lb_target_group.example.arn]

  tag {
    key                 = "Name"
    value               = "ASG-Instance"
    propagate_at_launch = true # 인스턴스에도 Name 태그 전파하여 콘솔에서 식별 가능하게 함
  }

  tag {
    key                 = "Project"
    value               = local.common_tags.Project
    propagate_at_launch = true # 인스턴스별 비용 추적을 위해 전파
  }

  tag {
    key                 = "Environment"
    value               = local.common_tags.Environment
    propagate_at_launch = true # 환경 구분을 인스턴스에도 전파
  }

  tag {
    key                 = "Owner"
    value               = local.common_tags.Owner
    propagate_at_launch = false # ASG 수준의 책임 소재 표시용이므로 개별 인스턴스에는 전파하지 않음
  }
}

# 애플리케이션 로드 밸런서(ALB) - 외부 HTTP 트래픽을 EC2 인스턴스로 분산
resource "aws_lb" "example" {
  name               = "example-alb"
  internal           = false         # 인터넷에서 접근 가능한 외부용 ALB
  load_balancer_type = "application" # L7 애플리케이션 로드 밸런서
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.alb.id] # ALB 전용 보안 그룹 사용

  # 잘못된 형식의 HTTP 헤더를 가진 요청 차단 (보안 강화)
  drop_invalid_header_fields = true

  enable_deletion_protection = false # 실습 환경이므로 삭제 방지 비활성화
}

# ALB 리스너 - 포트 80(HTTP)으로 들어오는 요청을 타겟 그룹으로 전달
resource "aws_lb_listener" "example" {
  load_balancer_arn = aws_lb.example.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.example.arn
  }
}

# ALB 타겟 그룹 - ALB가 트래픽을 전달할 EC2 인스턴스 집합 및 상태 확인 설정
resource "aws_lb_target_group" "example" {
  name        = "example-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance" # EC2 인스턴스를 직접 대상으로 등록
  vpc_id      = module.vpc.vpc_id

  health_check {
    path     = "/index.html" # nginx가 이 경로에 200 응답해야 정상으로 판단
    protocol = "HTTP"
  }
}

# 스케일 아웃 정책 - CPU가 높을 때 인스턴스를 1개 추가
resource "aws_autoscaling_policy" "scale_out_policy" {
  name                   = "scale-out-policy"
  scaling_adjustment     = 1 # 인스턴스 1개 추가
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300 # 스케일링 후 300초 동안 추가 스케일링 대기
  autoscaling_group_name = aws_autoscaling_group.example.name
}

# 스케일 인 정책 - CPU가 낮을 때 인스턴스를 1개 제거
resource "aws_autoscaling_policy" "scale_in_policy" {
  name                   = "scale-in-policy"
  scaling_adjustment     = -1 # 인스턴스 1개 감소
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.example.name
}

# CloudWatch 알람 - CPU 60% 이상 2회 연속 측정 시 스케일 아웃 트리거
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "cpu_high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2   # 숫자 타입으로 선언
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120 # 측정 주기 120초
  statistic           = "Average"
  threshold           = 60  # CPU 60% 이상이면 스케일 아웃
  alarm_actions       = [aws_autoscaling_policy.scale_out_policy.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.example.name
  }
}

# CloudWatch 알람 - CPU 30% 이하 2회 연속 측정 시 스케일 인 트리거
resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "cpu_low"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 30 # CPU 30% 이하이면 스케일 인
  alarm_actions       = [aws_autoscaling_policy.scale_in_policy.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.example.name
  }
}
