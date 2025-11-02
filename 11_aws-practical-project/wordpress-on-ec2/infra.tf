
resource "aws_launch_template" "wordpress" {
  name_prefix   = "wordpress-"
  image_id      = "ami-0cd913f496bae5294" # WordPress가 설치된 AMI ID로 변경하세요
  instance_type = "t2.micro"

  vpc_security_group_ids = [aws_security_group.wordpress_sg.id]

  user_data = base64encode(<<-EOF
              #!/bin/bash
              mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport ${aws_efs_file_system.wordpress_efs.dns_name}:/ /var/www/html
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "WordPress Instance"
    }
  }
}

resource "aws_autoscaling_group" "wordpress" {
  desired_capacity    = 2
  max_size            = 4
  min_size            = 2
  target_group_arns   = [aws_lb_target_group.wordpress.arn]
  vpc_zone_identifier = module.vpc.private_subnets

  launch_template {
    id      = aws_launch_template.wordpress.id
    version = "$Latest"
  }
}

resource "aws_security_group" "wordpress_sg" {
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "TCP"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "wordpress" {
  name               = "wordpress-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = module.vpc.public_subnets
}


resource "aws_lb_target_group" "wordpress" {
  name     = "wordpress-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.wordpress.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.wordpress.arn
  }
}

resource "aws_security_group" "lb_sg" {
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
