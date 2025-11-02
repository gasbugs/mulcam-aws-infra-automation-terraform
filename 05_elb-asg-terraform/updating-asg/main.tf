# random_integer 리소스: 키 페어 이름에 사용할 랜덤 값 생성
resource "random_integer" "example" {
  min = 1000
  max = 9999
}

# 기존 키 페어 사용
resource "aws_key_pair" "example" {
  key_name   = "example-keypair-${random_integer.example.result}"
  public_key = file(pathexpand(var.pub_key_file_path))
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0" # 원하는 버전으로 설정

  name                 = "example-vpc"
  cidr                 = "10.0.0.0/16"
  azs                  = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnets       = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets      = ["10.0.3.0/24", "10.0.4.0/24"]
  enable_dns_hostnames = true
  enable_dns_support   = true

  # 인터넷 게이트웨이 및 라우팅 테이블을 자동으로 생성
  create_igw = true

  # NAT 게이트웨이 활성화
  enable_nat_gateway = true
  single_nat_gateway = true # 하나의 NAT 게이트웨이만 사용할 경우 true 설정
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

# 로드 밸런서의 타겟 그룹 생성
resource "aws_lb_target_group" "example" {
  name     = "example-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id
  health_check {
    path     = "/"
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

  # 헬스 체크 타입과 그레이스 기간 설정
  health_check_type         = "EC2" # EC2 상태 확인을 헬스 체크 기준으로 설정
  health_check_grace_period = 180   # 헬스 체크가 시작되기 전에 기다릴 기간 (초)

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

# ALB 보안 그룹에 HTTPS 트래픽 허용 규칙 추가
resource "aws_security_group" "for_alb" {
  name_prefix = "for-alb"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  vpc_id = module.vpc.vpc_id
  tags = {
    Name = "for-alb"
  }
}


# EC2 보안 그룹에 HTTP 트래픽 허용 규칙 추가
resource "aws_security_group" "for_ec2" {
  name_prefix = "for-ec2"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
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
  vpc_id = module.vpc.vpc_id
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
