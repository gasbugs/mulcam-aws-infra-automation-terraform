# AMI 검색 
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

# EC2 인스턴스 생성
resource "aws_instance" "web_server" {
  ami           = data.aws_ami.al2023.id
  instance_type = var.instance_type

  # 태그 설정: 공통 태그 및 추가 태그를 병합
  tags = merge(
    {
      Name = var.instance_name
    },
    local.common_tags
  )
}

# 로컬 변수 설정: 공통 태그
locals {
  common_tags = {
    Project    = var.project
    CostCenter = var.cost_center
  }
}
