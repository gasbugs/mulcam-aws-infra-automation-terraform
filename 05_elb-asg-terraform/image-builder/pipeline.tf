##############################################################################
# [pipeline.tf] 전체 AMI 빌드 흐름을 하나로 묶는 파이프라인 (중심 파일)
#
# Image Pipeline은 나머지 모든 설정(Recipe, Infrastructure, Distribution)을
# 연결하여 "언제, 무엇을, 어디서, 어디에 저장할지"를 종합 정의합니다.
# Packer에서는 build {} 블록 하나가 이 역할을 모두 담당하지만,
# Image Builder는 관심사를 파일별로 분리하고 Pipeline이 이를 조립합니다.
# 이 파일에서 정의하는 것:
#   - Image Pipeline: recipe + infrastructure + distribution 세 설정을 연결
#   - 파이프라인 활성화 상태 (ENABLED)
#   - 빌드 완료 후 이미지 테스트 수행 여부 및 제한 시간
#
# 역할 연결: 수동 실행(aws imagebuilder start-image-pipeline-execution) 또는
#            스케줄로 트리거되면 이 파이프라인이 전체 빌드를 시작합니다.
##############################################################################

# Image Pipeline — Recipe, Infrastructure, Distribution을 하나로 연결하는 오케스트레이터
# "언제, 무엇을, 어디서, 어디에" 빌드할지를 종합 정의
resource "aws_imagebuilder_image_pipeline" "spring_boot" {
  name        = "spring-boot-app-pipeline-${var.environment}"
  description = "Spring Boot AMI를 자동으로 빌드하고 배포하는 Image Builder 파이프라인"

  # 빌드 설계도 (무엇을 만들지)
  image_recipe_arn = aws_imagebuilder_image_recipe.spring_boot.arn

  # 빌드 환경 (어디서 만들지)
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.spring_boot.arn

  # 배포 설정 (어디에 저장할지)
  distribution_configuration_arn = aws_imagebuilder_distribution_configuration.spring_boot.arn

  # 파이프라인 활성화 상태 — ENABLED: 스케줄/수동 실행 가능
  status = "ENABLED"

  # 빌드 완료 후 이미지 테스트 수행 여부 설정
  image_tests_configuration {
    image_tests_enabled = true
    timeout_minutes     = 60 # 테스트 제한 시간 (분)
  }

  tags = {
    Name        = "spring-boot-app-pipeline"
    Environment = var.environment
  }
}
