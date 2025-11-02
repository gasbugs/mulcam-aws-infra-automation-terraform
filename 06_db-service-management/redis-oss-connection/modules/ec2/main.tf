# Security Group for EC2
resource "aws_security_group" "ec2_sg" {
  name        = "${var.project_name}-ec2-sg"
  description = "Security group for EC2 instances"
  vpc_id      = var.vpc_id

  # Allow inbound SSH access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidr_blocks
  }

  # Allow inbound traffic to Redis port (6379)
  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = var.redis_cidr_blocks
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ec2-sg"
  }
}

// 랜덤한 문자열 생성 (Key Pair 이름 구성에 사용)
resource "random_string" "key_name_suffix" {
  length  = 8
  special = false
  upper   = false
}

// 랜덤 문자열을 포함한 Key Pair 이름 생성
resource "aws_key_pair" "my_key_pair" {
  key_name   = "my-key-${random_string.key_name_suffix.result}" // 랜덤한 이름 생성
  public_key = file(var.public_key_path)

  tags = {
    Name = "MyKeyPair-${random_string.key_name_suffix.result}"
  }
}

# EC2 Instance
resource "aws_instance" "ec2_instance" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  key_name                    = aws_key_pair.my_key_pair.key_name
  associate_public_ip_address = true

  iam_instance_profile = var.ec2_instance_profile

  # Optionally add user data for bootstrapping
  user_data = var.user_data

  tags = {
    Name = "${var.project_name}-ec2-instance"
  }
}
