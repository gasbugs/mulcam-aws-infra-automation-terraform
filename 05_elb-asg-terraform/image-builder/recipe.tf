##############################################################################
# [recipe.tf] AMI 설계도 — 베이스 이미지 + 컴포넌트 조합 정의
#
# Image Recipe는 "어떤 베이스 AMI 위에, 어떤 컴포넌트를 어떤 순서로
# 얹어서 최종 AMI를 만들지"를 정의하는 설계도입니다.
# Packer의 source_ami_filter + provisioner 목록을 하나로 묶은 개념입니다.
# 이 파일에서 정의하는 것:
#   - data "aws_ami": 베이스로 사용할 최신 Amazon Linux 2023 AMI 자동 조회
#   - Image Recipe: 베이스 AMI + 컴포넌트 실행 순서 + 루트 볼륨 크기(20GB)
#   - lifecycle create_before_destroy: 버전 업 시 파이프라인 의존성 오류 방지
#
# 역할 연결: components.tf의 컴포넌트 두 개를 순서대로 조합하며,
#            pipeline.tf가 이 레시피를 참조하여 빌드를 시작합니다.
##############################################################################

# 최신 Amazon Linux 2023 AMI 조회 — Packer의 source_ami_filter와 동일한 조건
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["137112412989"] # Amazon 공식 AMI 계정 ID

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Image Recipe — 베이스 AMI와 컴포넌트를 조합하여 "무엇을 만들지" 정의하는 설계도
resource "aws_imagebuilder_image_recipe" "spring_boot" {
  name        = "spring-boot-app-recipe-${var.environment}-${random_string.suffix.result}"
  description = "Amazon Linux 2023 위에 Java 17과 Spring Boot 앱을 설치한 AMI 설계도"
  version     = var.recipe_version

  # 빌드의 출발점이 되는 베이스 AMI (Amazon Linux 2023 최신 버전)
  parent_image = data.aws_ami.al2023.id

  # 컴포넌트 적용 순서 — Java 설치 후 앱 배포 (순서가 중요)
  component {
    component_arn = aws_imagebuilder_component.install_java17.arn
  }

  component {
    component_arn = aws_imagebuilder_component.deploy_spring_app.arn
  }

  # 루트 볼륨 설정 — 기본 8GB에서 20GB로 확장하여 앱 실행 공간 확보
  block_device_mapping {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20   # GB
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  tags = {
    Name        = "spring-boot-app-recipe"
    Environment = var.environment
  }

  # 버전 변경 시 새 레시피를 먼저 생성한 뒤 파이프라인이 참조를 교체하고 나서 구 레시피를 삭제
  # 이 옵션이 없으면 파이프라인 의존성 때문에 구 레시피 삭제가 실패함
  lifecycle {
    create_before_destroy = true
  }
}
