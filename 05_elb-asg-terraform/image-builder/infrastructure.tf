##############################################################################
# [infrastructure.tf] AMI를 빌드할 EC2 환경 설정 (Packer의 builder 블록에 해당)
#
# Infrastructure Configuration은 Image Builder가 AMI를 만들 때
# "어떤 EC2 인스턴스를 사용할지"를 정의합니다.
# Packer의 source "amazon-ebs" 블록에서 instance_type, iam_instance_profile
# 등을 설정하는 것과 같은 역할을 합니다.
# 이 파일에서 정의하는 것:
#   - CloudWatch Log Group: 빌드 로그를 30일간 보관하는 공간
#   - Infrastructure Configuration: 빌드용 EC2 타입(t3.micro), IAM 프로파일,
#     실패 시 자동 종료 여부, 로그 저장 위치(S3)
#
# 역할 연결: pipeline.tf가 이 설정을 참조하여 빌드 인스턴스를 생성합니다.
##############################################################################

# CloudWatch 로그 그룹 — Image Builder 빌드 로그를 중앙에서 조회하고 보관하는 공간
resource "aws_cloudwatch_log_group" "image_builder" {
  name              = "/aws/imagebuilder/spring-boot-app-${var.environment}-${random_string.suffix.result}"
  retention_in_days = 30 # 30일 후 자동 삭제하여 불필요한 로그 비용 방지

  tags = {
    Name        = "imagebuilder-spring-boot-logs"
    Environment = var.environment
  }
}

# Infrastructure Configuration — "어떤 EC2에서 빌드할지" 정의
# Packer의 instance_type, ssh_username 설정에 해당
resource "aws_imagebuilder_infrastructure_configuration" "spring_boot" {
  name                          = "spring-boot-infra-config-${var.environment}-${random_string.suffix.result}"
  description                   = "Spring Boot AMI 빌드에 사용할 EC2 인스턴스 설정"
  instance_profile_name         = aws_iam_instance_profile.image_builder.name
  instance_types                = ["t3.micro"] # Packer와 동일한 인스턴스 타입
  terminate_instance_on_failure = true          # 빌드 실패 시 EC2 자동 종료로 비용 방지

  # 빌드 로그를 CloudWatch Logs로 전송하는 설정
  logging {
    s3_logs {
      s3_bucket_name = aws_s3_bucket.image_builder_artifacts.id
      s3_key_prefix  = "logs/imagebuilder/"
    }
  }

  tags = {
    Name        = "spring-boot-infra-config"
    Environment = var.environment
  }
}
