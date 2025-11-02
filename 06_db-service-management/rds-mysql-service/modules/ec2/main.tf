resource "aws_instance" "ec2_instance" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  key_name                    = aws_key_pair.ec2_key_pair.key_name
  associate_public_ip_address = true # Public IP 할당

  tags = {
    Name = var.instance_name
  }
}

resource "random_integer" "random_number" {
  min = 1000
  max = 9999
}

# EC2에 사용할 키 페어 생성
resource "aws_key_pair" "ec2_key_pair" {
  key_name   = "ec2-key-pair-${random_integer.random_number.result}"
  public_key = file(pathexpand(var.public_key_path))
}

# EC2 인스턴스를 위한 보안 그룹 생성
resource "aws_security_group" "ec2_sg" {
  vpc_id      = var.vpc_id
  name_prefix = "ec2-public-sg-"

  # SSH 및 HTTP 인바운드 트래픽 허용
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # SSH 접근 허용
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # HTTP 접근 허용
  }

  # 모든 아웃바운드 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
