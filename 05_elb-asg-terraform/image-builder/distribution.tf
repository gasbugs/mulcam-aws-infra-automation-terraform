##############################################################################
# [distribution.tf] 완성된 AMI의 이름과 배포 대상 리전 설정
#
# Distribution Configuration은 Image Builder가 AMI 생성을 마친 뒤
# "어디에, 어떤 이름으로 등록할지"를 정의합니다.
# Packer의 ami_name, ami_tags, region 설정에 해당합니다.
# 이 파일에서 정의하는 것:
#   - AMI 이름 규칙 (접두사 + 빌드 날짜 자동 삽입)
#   - AMI에 붙일 태그 (Name, BuildDate, OS, App 등)
#   - AMI를 등록할 리전
#
# 역할 연결: pipeline.tf가 이 설정을 참조하여 빌드 완료 후 AMI를 등록합니다.
##############################################################################

# Distribution Configuration — 완성된 AMI를 어느 리전에, 어떤 이름으로 배포할지 정의
# Packer의 ami_name, tags, region 설정에 해당
resource "aws_imagebuilder_distribution_configuration" "spring_boot" {
  name        = "spring-boot-dist-config-${var.environment}"
  description = "완성된 Spring Boot AMI의 이름과 배포 리전을 정의합니다"

  distribution {
    region = var.aws_region

    ami_distribution_configuration {
      # {{ imagebuilder:buildDate }} — Image Builder가 자동으로 빌드 날짜를 삽입하는 템플릿 변수
      name        = "${var.ami_name_prefix}-{{ imagebuilder:buildDate }}"
      description = "Spring Boot App on Amazon Linux 2023 (Java 17)"

      ami_tags = {
        Name        = var.ami_name_prefix
        BuildDate   = "{{ imagebuilder:buildDate }}"
        OS          = "Amazon Linux 2023"
        App         = "Spring Boot"
        Environment = var.environment
        ManagedBy   = "ImageBuilder+Terraform"
      }
    }
  }

  tags = {
    Name        = "spring-boot-dist-config"
    Environment = var.environment
  }
}
