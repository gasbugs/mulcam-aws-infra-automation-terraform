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
  load_balancer_arn = aws_lb.example.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate.example.arn

  default_action {
    target_group_arn = aws_lb_target_group.example.arn
    type             = "forward"
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
    path     = "/index.html"
    protocol = "HTTP"
  }
}


# 오토 스케일링 그룹 생성 및 타겟 그룹 연결
resource "aws_autoscaling_group" "example" {
  launch_template {
    id      = aws_launch_template.example.id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = 300

  vpc_zone_identifier = module.vpc.private_subnets
  desired_capacity    = 2
  max_size            = 3
  min_size            = 1

  tag {
    key                 = "Name"
    value               = "ASG-Instance"
    propagate_at_launch = true
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

# Amazon Linux 2023 AMI ID를 가져오는 data 블록
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

# 부트스트랩 스크립트를 로컬 변수로 정의
locals {
  bootstrap_script = base64encode(<<-EOT
    #!/bin/bash
    yum install -y nginx
    systemctl start nginx
    echo "Hello, Nginx! $(hostname)" > /usr/share/nginx/html/index.html
  EOT
  )
}

# Launch Template을 정의
resource "aws_launch_template" "example" {
  name_prefix   = "example-launch-template"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  key_name  = aws_key_pair.example.key_name
  user_data = local.bootstrap_script

  network_interfaces {
    security_groups = [aws_security_group.for_ec2.id]
  }
}
