##############################################################################
# [s3.tf] 빌드 로그 저장소
#
# S3(Simple Storage Service)는 파일을 저장하는 AWS 오브젝트 스토리지입니다.
# Image Builder 빌드 인스턴스는 실행 로그(AWSTOE 로그)를 S3에 업로드합니다.
# 이 파일에서 정의하는 것:
#   - S3 버킷: 빌드 로그(logs/imagebuilder/) 저장 공간
#             계정 ID를 이름에 포함하여 전 세계 유일한 이름 보장
#   - Public Access Block: 외부에서 버킷 내용을 볼 수 없도록 모든 공개 접근 차단
#
# 역할 연결: infrastructure.tf가 빌드 로그 저장 위치로 이 버킷을 참조하며,
#            iam.tf가 빌드 인스턴스에 이 버킷 쓰기 권한을 부여합니다.
##############################################################################

# S3 버킷 — Image Builder가 사용할 아티팩트(JAR 파일)와 빌드 로그를 저장하는 공간
resource "aws_s3_bucket" "image_builder_artifacts" {
  # 계정 ID를 포함시켜 전 세계에서 유일한 버킷 이름 생성
  bucket = "image-builder-artifacts-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name        = "image-builder-artifacts"
    Environment = var.environment
  }
}

# 버킷에 저장된 객체의 공개 접근을 차단 — IAM 권한이 있는 서비스만 접근 가능
resource "aws_s3_bucket_public_access_block" "image_builder_artifacts" {
  bucket = aws_s3_bucket.image_builder_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# JAR 파일 S3 업로드는 CodeCommit 연동 이후 불필요 — 빌드는 Image Builder 인스턴스 내부에서 수행됨
