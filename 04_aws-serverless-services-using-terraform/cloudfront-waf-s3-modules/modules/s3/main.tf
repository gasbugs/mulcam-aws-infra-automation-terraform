# S3 버킷 이름은 전 세계에서 유일해야 합니다.
# 같은 이름의 버킷이 이미 있으면 생성 오류가 발생하므로, 끝에 랜덤 숫자를 붙여 충돌을 방지합니다.
resource "random_integer" "bucket_suffix" {
  min = 1000
  max = 9999
}

# 정적 웹사이트 파일(HTML, CSS, 이미지 등)을 저장할 S3 버킷을 만듭니다.
# S3(Simple Storage Service)는 AWS에서 제공하는 파일 저장 서비스입니다.
resource "aws_s3_bucket" "static_site" {
  bucket = "${var.bucket_name}-${random_integer.bucket_suffix.result}" # 이름 끝에 랜덤 숫자를 붙여 유일성 보장

  tags = {
    Name        = var.bucket_name # 리소스를 구분하기 위한 이름 태그
    Environment = var.environment # 운영 환경 태그 (dev / prod)
  }
}

# S3 버킷을 외부에서 직접 접근하지 못하도록 완전히 잠급니다.
# CloudFront OAC(Origin Access Control) 방식을 쓸 때는 반드시 퍼블릭 접근을 차단해야 합니다.
# 웹사이트 방문자는 CloudFront를 통해서만 파일을 받아볼 수 있습니다.
resource "aws_s3_bucket_public_access_block" "static_site" {
  bucket                  = aws_s3_bucket.static_site.id
  block_public_acls       = true # 퍼블릭 ACL(접근 제어 목록) 설정 자체를 차단
  block_public_policy     = true # 퍼블릭 버킷 정책 추가를 차단
  ignore_public_acls      = true # 기존 퍼블릭 ACL이 있어도 무시
  restrict_public_buckets = true # 퍼블릭 버킷 정책이 있어도 공개 접근 차단
}

# 웹사이트의 첫 화면(index.html)을 S3 버킷에 업로드합니다.
# etag는 파일의 고유 해시값으로, 파일 내용이 바뀌면 Terraform이 자동으로 재업로드합니다.
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.static_site.id
  key          = var.index_document               # S3에 저장될 파일 이름 (예: index.html)
  source       = var.index_document_path          # 내 컴퓨터에서 가져올 파일 경로
  content_type = "text/html"                      # 브라우저에게 HTML 파일임을 알려주는 타입
  etag         = filemd5(var.index_document_path) # 파일 변경 여부 감지용 해시값
}

# 존재하지 않는 페이지에 접속했을 때 보여줄 에러 페이지(error.html)를 업로드합니다.
resource "aws_s3_object" "error" {
  bucket       = aws_s3_bucket.static_site.id
  key          = var.error_document      # S3에 저장될 파일 이름 (예: error.html)
  source       = var.error_document_path # 내 컴퓨터에서 가져올 파일 경로
  content_type = "text/html"
  etag         = filemd5(var.error_document_path) # 파일 변경 여부 감지용 해시값
}
