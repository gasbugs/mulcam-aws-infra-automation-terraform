# 키 페어를 정의
# 1000부터 9999 사이의 랜덤 값을 생성
resource "random_integer" "example" {
  min = 1000
  max = 9999
}

# 생성된 랜덤 값을 포함하여 키 페어 생성
resource "aws_key_pair" "example" {
  key_name   = "example-keypair-${random_integer.example.result}"
  public_key = file(pathexpand(var.pub_key_file_path)) # 사용자 지정 경로의 공개 키 파일 불러오기
}

# VPC 모듈 생성
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0" # 원하는 버전으로 설정

  # VPC 이름 및 CIDR 범위 설정
  name                 = "example-vpc"
  cidr                 = "10.0.0.0/16"
  azs                  = ["${var.aws_region}a", "${var.aws_region}b"] # 가용 영역 설정
  public_subnets       = ["10.0.1.0/24", "10.0.2.0/24"]               # 퍼블릭 서브넷 CIDR
  private_subnets      = ["10.0.3.0/24", "10.0.4.0/24"]               # 프라이빗 서브넷 CIDR
  enable_dns_hostnames = true                                         # DNS 호스트 이름 활성화
  enable_dns_support   = true                                         # DNS 지원 활성화

  # 인터넷 게이트웨이 및 라우팅 테이블 자동 생성
  create_igw = true

  # NAT 게이트웨이 설정 (하나만 사용)
  #enable_nat_gateway = true
  #single_nat_gateway = true # 하나의 NAT 게이트웨이만 사용할 경우 true 설정

  public_subnet_tags = {
    Name = "example-public-subnet" # 퍼블릭 서브넷에 이름 태그 추가
  }

  tags = {
    Name = "example-vpc" # VPC에 이름 태그 추가
  }
}

# Launch Template을 정의하여 인스턴스 시작 템플릿 설정
resource "aws_launch_template" "example" {
  name_prefix   = "example-launch-template"
  image_id      = var.packer_ami    # 패커로 빌드한 후 생성된 ami 사용
  instance_type = var.instance_type # 인스턴스 유형 변수 사용

  key_name = aws_key_pair.example.key_name # 생성된 키 페어 이름 설정

  # 네트워크 인터페이스 설정 (보안 그룹 포함)
  network_interfaces {
    security_groups = [aws_security_group.example.id]
  }
}

# 오토 스케일링 그룹 정의
resource "aws_autoscaling_group" "example" {
  launch_template {
    id      = aws_launch_template.example.id # Launch Template ID 참조
    version = "$Latest"
  }
  # EC2 인스턴스 상태 확인 방식 설정
  health_check_type         = "EC2" # EC2 상태 확인 방식 사용
  health_check_grace_period = 300   # 인스턴스 상태 확인 대기 시간 300초

  # 프라이빗 서브넷에 인스턴스 배포
  vpc_zone_identifier = module.vpc.private_subnets # 오토 스케일링 그룹의 VPC 서브넷 설정
  desired_capacity    = 2                          # 초기 인스턴스 수 2개
  max_size            = 3                          # 최대 인스턴스 수 3개
  min_size            = 1                          # 최소 인스턴스 수 1개
}

# 애플리케이션 로드 밸런서 설정
resource "aws_lb" "example" {
  name               = "example-alb"                   # 로드 밸런서 이름
  internal           = false                           # 외부 접근 가능하도록 설정
  load_balancer_type = "application"                   # ALB 유형 설정
  subnets            = module.vpc.public_subnets       # 퍼블릭 서브넷에 배치
  security_groups    = [aws_security_group.example.id] # 연결된 보안 그룹 ID

  enable_deletion_protection = false # 삭제 방지 비활성화
}

# 로드 밸런서 리스너 설정
resource "aws_lb_listener" "example" {
  load_balancer_arn = aws_lb.example.arn # 연결할 로드 밸런서 ARN
  port              = "80"               # 리스너 포트 번호 (HTTP)
  protocol          = "HTTP"             # 리스너 프로토콜 (HTTP)
  default_action {
    target_group_arn = aws_lb_target_group.example.arn # 포워딩 대상 타겟 그룹 ARN
    type             = "forward"                       # 기본 동작을 타겟 그룹으로 포워딩
  }
}

# 로드 밸런서의 타겟 그룹 설정
resource "aws_lb_target_group" "example" {
  name     = "example-tg"      # 타겟 그룹 이름
  port     = 80                # 타겟 그룹 포트 번호 (HTTP)
  protocol = "HTTP"            # 타겟 그룹 프로토콜 (HTTP)
  vpc_id   = module.vpc.vpc_id # 타겟 그룹의 VPC ID
  health_check {
    path     = "/index.html" # 상태 확인 경로
    protocol = "HTTP"        # 상태 확인 프로토콜 (HTTP)
  }
}

# 오토 스케일링 그룹 인스턴스를 타겟 그룹에 연결
resource "aws_autoscaling_attachment" "example" {
  autoscaling_group_name = aws_autoscaling_group.example.name # 연결할 오토 스케일링 그룹 이름
  lb_target_group_arn    = aws_lb_target_group.example.arn    # 연결할 타겟 그룹 ARN
}

# HTTP 및 SSH 트래픽을 허용하는 보안 그룹 정의
resource "aws_security_group" "example" {
  name_prefix = "example-sg" # 보안 그룹 이름 접두사
  # ingress {
  #   from_port   = 22            # 허용할 SSH 포트 (22)
  #   to_port     = 22            # 허용할 SSH 포트 (22)
  #   protocol    = "tcp"         # 프로토콜 (TCP)
  #   cidr_blocks = ["0.0.0.0/0"] # 모든 IP에서 SSH 트래픽 허용
  # }
  ingress {
    from_port   = 80            # 허용할 HTTP 포트 (80)
    to_port     = 80            # 허용할 HTTP 포트 (80)
    protocol    = "tcp"         # 프로토콜 (TCP)
    cidr_blocks = ["0.0.0.0/0"] # 모든 IP에서 HTTP 트래픽 허용
  }
  egress {
    from_port   = 0             # 아웃바운드 포트 범위 시작
    to_port     = 0             # 아웃바운드 포트 범위 끝
    protocol    = "-1"          # 모든 프로토콜 허용
    cidr_blocks = ["0.0.0.0/0"] # 모든 IP로의 아웃바운드 트래픽 허용
  }
  vpc_id = module.vpc.vpc_id # 연결할 VPC ID
  tags = {
    Name = "example-sg" # 보안 그룹에 이름 태그 추가
  }
}

# 오토 스케일링 정책 정의 (스케일 아웃)
resource "aws_autoscaling_policy" "scale_out_policy" {
  name                   = "scale-out-policy"                 # 스케일 아웃 정책 이름
  scaling_adjustment     = 1                                  # 인스턴스 1개 추가
  adjustment_type        = "ChangeInCapacity"                 # 용량 변경 유형으로 설정
  cooldown               = 300                                # 정책 쿨다운 기간 300초
  autoscaling_group_name = aws_autoscaling_group.example.name # 대상 오토 스케일링 그룹 이름
}

# 오토 스케일링 정책 정의 (스케일 인)
resource "aws_autoscaling_policy" "scale_in_policy" {
  name                   = "scale-in-policy"                  # 스케일 인 정책 이름
  scaling_adjustment     = -1                                 # 인스턴스 1개 감소
  adjustment_type        = "ChangeInCapacity"                 # 용량 변경 유형으로 설정
  cooldown               = 300                                # 정책 쿨다운 기간 300초
  autoscaling_group_name = aws_autoscaling_group.example.name # 대상 오토 스케일링 그룹 이름
}

# CPU 사용률이 높을 때 알람을 설정하여 스케일 아웃 트리거
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "cpu_high"                                    # 알람 이름
  comparison_operator = "GreaterThanOrEqualToThreshold"               # 임계값 이상일 때 트리거
  evaluation_periods  = "2"                                           # 평가 기간 2회
  metric_name         = "CPUUtilization"                              # CPU 사용률 메트릭
  namespace           = "AWS/EC2"                                     # 메트릭 네임스페이스
  period              = "120"                                         # 측정 주기 120초
  statistic           = "Average"                                     # 평균 값 사용
  threshold           = "60"                                          # 임계값 60%
  alarm_actions       = [aws_autoscaling_policy.scale_out_policy.arn] # 스케일 아웃 정책으로 연결
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.example.name # 오토 스케일링 그룹 이름과 연결
  }
}

# CPU 사용률이 낮을 때 알람을 설정하여 스케일 인 트리거
resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "cpu_low"                                    # 알람 이름
  comparison_operator = "LessThanOrEqualToThreshold"                 # 임계값 이하일 때 트리거
  evaluation_periods  = "2"                                          # 평가 기간 2회
  metric_name         = "CPUUtilization"                             # CPU 사용률 메트릭
  namespace           = "AWS/EC2"                                    # 메트릭 네임스페이스
  period              = "120"                                        # 측정 주기 120초
  statistic           = "Average"                                    # 평균 값 사용
  threshold           = "30"                                         # 임계값 30%
  alarm_actions       = [aws_autoscaling_policy.scale_in_policy.arn] # 스케일 인 정책으로 연결
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.example.name # 오토 스케일링 그룹 이름과 연결
  }
}
