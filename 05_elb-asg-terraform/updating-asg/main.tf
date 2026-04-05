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

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0" # 원하는 버전으로 설정

  name                 = "example-vpc"
  cidr                 = var.vpc_cidr                                  # 변수로 관리하여 환경별 네트워크 대역 유연하게 변경 가능
  azs                  = ["${var.aws_region}a", "${var.aws_region}b"] # 가용 영역 2개 설정
  public_subnets       = var.public_subnets                           # 퍼블릭 서브넷 CIDR
  private_subnets      = var.private_subnets                          # 프라이빗 서브넷 CIDR
  enable_dns_hostnames = true # DNS 호스트 이름 활성화
  enable_dns_support   = true # DNS 지원 활성화

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

# ACM 인증서 리소스: 사용자의 인증서를 ACM에 업로드
resource "aws_acm_certificate" "example" {
  private_key      = file(var.private_key_file_path)
  certificate_body = file(var.certificate_body_file_path)
  # certificate_chain = file(var.certificate_chain_file_path)
}

# 로드 밸런서 생성
resource "aws_lb" "example" {
  name                       = "example-alb"
  internal                   = false
  load_balancer_type         = "application"
  subnets                    = module.vpc.public_subnets
  security_groups            = [aws_security_group.for_alb.id]
  enable_deletion_protection = false

  # 잘못된 형식의 HTTP 헤더를 가진 요청 차단 (보안 강화)
  drop_invalid_header_fields = true
}

# HTTPS 리스너 설정
resource "aws_lb_listener" "https_listener" {
  load_balancer_arn = aws_lb.example.arn              # 연결할 로드 밸런서의 ARN
  port              = "443"                           # HTTPS 리스너 포트 (443)
  protocol          = "HTTPS"                         # 리스너 프로토콜 (HTTPS)
  ssl_policy        = "ELBSecurityPolicy-2016-08"     # HTTPS 보안 정책 설정
  certificate_arn   = aws_acm_certificate.example.arn # HTTPS 인증서의 ARN (ACM 인증서 사용)

  # 기본 동작 설정
  default_action {
    target_group_arn = aws_lb_target_group.example.arn # 요청을 포워딩할 타겟 그룹의 ARN
    type             = "forward"                       # 기본 동작 유형: 타겟 그룹으로 포워딩
  }
}


# HTTP -> HTTPS 리다이렉션 설정 (옵션)
resource "aws_lb_listener" "http_redirect_listener" {
  load_balancer_arn = aws_lb.example.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ALB 타겟 그룹 - ALB가 트래픽을 전달할 EC2 인스턴스 집합 및 상태 확인 설정
resource "aws_lb_target_group" "example" {
  name        = "example-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"     # EC2 인스턴스를 직접 대상으로 등록
  vpc_id      = module.vpc.vpc_id

  health_check {
    path     = "/" # httpd가 이 경로에 200 응답해야 정상으로 판단
    protocol = "HTTP"
  }
}

# 오토 스케일링 그룹 생성 및 타겟 그룹 연결
resource "aws_autoscaling_group" "example" {
  # ASG에서 인스턴스가 생성될 때 사용할 Launch Template 설정
  launch_template {
    id      = aws_launch_template.example.id
    version = "$Latest" # 가장 최신 버전의 Launch Template을 사용
  }

  # ALB 상태 확인 방식 사용 (httpd가 실제로 응답하는지 확인 후 비정상 인스턴스 교체)
  health_check_type         = "ELB"
  health_check_grace_period = 300 # 인스턴스 부팅 및 httpd 시작 대기 시간 300초

  # VPC 내에서 ASG가 사용할 서브넷 설정 (다중 가용 영역에 분산 배치)
  vpc_zone_identifier = module.vpc.private_subnets
  desired_capacity    = var.desired_capacity # 원하는 인스턴스 개수 (실행 중인 인스턴스 수)
  max_size            = var.max_size         # ASG가 스케일링될 때 최대 인스턴스 수
  min_size            = var.min_size         # ASG의 최소 인스턴스 수

  # 인스턴스 태그 설정
  tag {
    key                 = "Name"
    value               = var.asg_tag # 인스턴스에 적용될 태그 값
    propagate_at_launch = true        # 인스턴스 생성 시 태그를 자동으로 적용
  }

  # ASG 업데이트를 위한 instance_refresh 설정
  instance_refresh {
    strategy = "Rolling" # 롤링 업데이트 전략 사용 (순차적 교체)

    preferences {
      instance_warmup        = 100 # 인스턴스가 시작된 후 안정화되는 데 필요한 대기 시간 (초)
      min_healthy_percentage = 50  # 교체 과정 중 최소 50%의 인스턴스가 정상 상태를 유지
    }

    # instance_refresh를 트리거하는 조건
    triggers = ["tag"] # 태그 변경 시 인스턴스 교체 프로세스 시작
  }

  # Terraform이 관리하지 않는 특정 속성을 무시하도록 설정
  lifecycle {
    ignore_changes = [load_balancers, target_group_arns] # 로드 밸런서와 타겟 그룹 변경 무시
  }
}


# 오토 스케일링 그룹 인스턴스를 타겟 그룹에 연결
resource "aws_autoscaling_attachment" "example" {
  autoscaling_group_name = aws_autoscaling_group.example.name
  lb_target_group_arn    = aws_lb_target_group.example.arn
}

# ALB(로드 밸런서)용 보안 그룹 - 인터넷에서 HTTP/HTTPS 트래픽 허용
resource "aws_security_group" "for_alb" {
  name_prefix = "for-alb"
  description = "Allow HTTP and HTTPS from internet"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow HTTP from internet" # HTTP→HTTPS 리다이렉션을 위해 80도 허용
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTPS from internet"
    from_port   = 443
    to_port     = 443
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
    Name = "for-alb"
  }
}

# EC2 인스턴스용 보안 그룹 - ALB에서 오는 트래픽만 허용 (직접 인터넷 접근 차단)
resource "aws_security_group" "for_ec2" {
  name_prefix = "for-ec2"
  description = "Allow HTTP from ALB only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Allow HTTP from ALB only" # ALB 보안 그룹에서 오는 HTTP 트래픽만 허용
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.for_alb.id] # ALB SG에서 오는 트래픽만 허용
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "for-ec2"
  }
}

# Launch Template 생성
resource "aws_launch_template" "example" {
  name_prefix   = "example-launch-template"
  image_id      = var.ami_id
  instance_type = var.instance_type

  key_name = aws_key_pair.example.key_name

  network_interfaces {
    security_groups = [aws_security_group.for_ec2.id]
  }
}

# 스케일 아웃 정책 - CPU가 높을 때 인스턴스를 1개 추가
resource "aws_autoscaling_policy" "scale_out_policy" {
  name                   = "scale-out-policy"
  scaling_adjustment     = 1                  # 인스턴스 1개 추가
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300                # 스케일링 후 300초 동안 추가 스케일링 대기
  autoscaling_group_name = aws_autoscaling_group.example.name
}

# 스케일 인 정책 - CPU가 낮을 때 인스턴스를 1개 제거
resource "aws_autoscaling_policy" "scale_in_policy" {
  name                   = "scale-in-policy"
  scaling_adjustment     = -1                 # 인스턴스 1개 감소
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.example.name
}

# CloudWatch 알람 - CPU 60% 이상 2회 연속 측정 시 스케일 아웃 트리거
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "cpu_high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2            # 2회 연속 측정
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120          # 측정 주기 120초
  statistic           = "Average"
  threshold           = 60           # CPU 60% 이상이면 스케일 아웃
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
  threshold           = 30           # CPU 30% 이하이면 스케일 인
  alarm_actions       = [aws_autoscaling_policy.scale_in_policy.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.example.name
  }
}
