# 키 페어를 정의
# 1000부터 9999 사이의 랜덤 값을 생성
resource "random_integer" "example" {
  min = 1000
  max = 9999
}

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

  user_data = local.bootstrap_script

  key_name = aws_key_pair.example.key_name

  network_interfaces {
    security_groups = [aws_security_group.example.id]
  }
}

locals {
  common_tags = {
    Project     = "MarketingApp"
    Environment = "Production"
    Owner       = "TeamA"
  }
}

# 오토 스케일링 그룹을 정의
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

  tag {
    key                 = "Project"
    value               = local.common_tags.Project
    propagate_at_launch = true
  }

  tag {
    key   = "Owner"
    value = local.common_tags.Owner
    # PII와 같은 민감한 정보일 수 있으므로 전파하지 않음(또는 정교한 사회공학기법으로 사용 가능)
    propagate_at_launch = false
  }
}

# 애플리케이션 로드 밸런서를 정의
resource "aws_lb" "example" {
  name               = "example-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.example.id]

  enable_deletion_protection = false # 삭제 방지 옵션
}

# 로드 밸런서의 리스너와 타겟 그룹을 정의
resource "aws_lb_listener" "example" {
  load_balancer_arn = aws_lb.example.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    target_group_arn = aws_lb_target_group.example.arn
    type             = "forward"
  }
}

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

# 오토 스케일링 그룹 인스턴스를 타겟 그룹에 연결
resource "aws_autoscaling_attachment" "example" {
  autoscaling_group_name = aws_autoscaling_group.example.name
  lb_target_group_arn    = aws_lb_target_group.example.arn
}

# HTTP 및 SSH 트래픽을 허용하는 보안 그룹을 정의
resource "aws_security_group" "example" {
  name_prefix = "example-sg"
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
    Name = "example-sg"
  }
}

resource "aws_autoscaling_policy" "scale_out_policy" {
  name                   = "scale-out-policy"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.example.name
}

resource "aws_autoscaling_policy" "scale_in_policy" {
  name                   = "scale-in-policy"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.example.name
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "cpu_high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "60"
  alarm_actions       = [aws_autoscaling_policy.scale_out_policy.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.example.name
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "cpu_low"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "30"
  alarm_actions       = [aws_autoscaling_policy.scale_in_policy.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.example.name
  }
}
