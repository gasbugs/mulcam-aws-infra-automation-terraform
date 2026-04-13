
# EC2 인스턴스 실행 시 사용할 설정 템플릿 (Launch Template)
# Packer로 만든 WordPress AMI를 기반으로 인스턴스를 시작하고, EFS를 마운트
resource "aws_launch_template" "wordpress" {
  name_prefix   = "wordpress-"
  image_id      = data.aws_ami.wordpress.id # Packer가 빌드한 최신 WordPress AMI를 동적으로 참조
  instance_type = "t3.micro"                # t2.micro보다 성능이 향상된 최신 인스턴스 유형

  vpc_security_group_ids = [aws_security_group.wordpress_sg.id]

  # 인스턴스 시작 시 자동으로 실행되는 초기화 스크립트
  user_data = base64encode(<<-EOF
    #!/bin/bash
    # 1. EFS 공유 스토리지를 /var/www/html에 마운트 (WordPress 파일 공유)
    mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport ${aws_efs_file_system.wordpress_efs.dns_name}:/ /var/www/html

    # 2. EFS 마운트 및 httpd 서비스 준비 대기 (최대 60초)
    for i in $(seq 1 12); do
      if mountpoint -q /var/www/html && [ -f /var/www/html/wp-config.php ]; then
        break
      fi
      sleep 5
    done

    # 3. Packer 빌드 시 example.com으로 설정된 WordPress URL을 실제 ALB 도메인으로 업데이트
    # wp-cli를 사용해 RDS의 wp_options 테이블에서 siteurl/home 값을 변경
    cd /var/www/html
    wp option update siteurl 'http://${aws_lb.wordpress.dns_name}' --allow-root
    wp option update home    'http://${aws_lb.wordpress.dns_name}' --allow-root

    # 4. Apache 웹 서버 시작
    systemctl enable httpd
    systemctl start httpd
    EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "WordPress Instance"
    }
  }

  # Packer AMI 빌드가 완료된 후 Launch Template을 생성해야 올바른 AMI ID를 참조
  depends_on = [terraform_data.packer_build]
}

# Auto Scaling Group: 웹 서버 EC2 인스턴스를 자동으로 늘리고 줄이는 그룹
resource "aws_autoscaling_group" "wordpress" {
  desired_capacity    = 2 # 평소 유지할 인스턴스 수
  max_size            = 3 # 트래픽 증가 시 최대 확장 가능한 인스턴스 수
  min_size            = 2 # 장애 대응을 위해 최소 유지할 인스턴스 수
  target_group_arns   = [aws_lb_target_group.wordpress.arn]
  vpc_zone_identifier = module.vpc.private_subnets # 외부에서 직접 접근 불가한 프라이빗 서브넷에 배치

  launch_template {
    id      = aws_launch_template.wordpress.id
    version = "$Latest"
  }
}

# EC2 WordPress 인스턴스에 대한 보안 그룹 (로드밸런서에서만 HTTP 허용)
resource "aws_security_group" "wordpress_sg" {
  name        = "wordpress-ec2-security-group"
  description = "Security group for WordPress EC2 instances - allows HTTP(80) from internal VPC only"
  vpc_id      = module.vpc.vpc_id

  # VPC 내부 트래픽(로드밸런서)에서만 HTTP 접근 허용 (인터넷에서 직접 접근 불가)
  ingress {
    description = "Allow HTTP from internal VPC only"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # VPC CIDR 범위만 허용
  }

  # 모든 아웃바운드 트래픽 허용 (패키지 설치, AWS API 호출 등)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "wordpress-ec2-sg"
  }
}

# Application Load Balancer: 여러 EC2 인스턴스에 트래픽을 분산시키는 로드밸런서
resource "aws_lb" "wordpress" {
  name               = "wordpress-lb"
  internal           = false            # 인터넷에서 접근 가능한 외부 로드밸런서
  load_balancer_type = "application"    # HTTP/HTTPS 트래픽을 처리하는 ALB(Application Load Balancer)
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = module.vpc.public_subnets # 인터넷에서 접근 가능한 퍼블릭 서브넷에 배치
}

# 로드밸런서가 트래픽을 전달할 대상 그룹 (EC2 인스턴스들의 모음)
resource "aws_lb_target_group" "wordpress" {
  name     = "wordpress-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  # 헬스 체크: EC2 인스턴스가 정상인지 주기적으로 확인
  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}

# 로드밸런서 리스너: 외부 HTTP 요청을 받아 대상 그룹으로 전달하는 규칙
resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.wordpress.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.wordpress.arn
  }
}

# 로드밸런서에 대한 보안 그룹 (인터넷에서 HTTP 접근 허용)
resource "aws_security_group" "lb_sg" {
  name        = "wordpress-lb-security-group"
  description = "Security group for WordPress ALB - allows HTTP(80) from the internet"
  vpc_id      = module.vpc.vpc_id

  # 인터넷 전체에서 HTTP(80) 접근 허용 (웹사이트 공개 접근용)
  ingress {
    description = "Allow HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 모든 아웃바운드 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "wordpress-lb-sg"
  }
}
