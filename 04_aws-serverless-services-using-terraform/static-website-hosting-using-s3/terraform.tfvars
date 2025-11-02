# terraform.tfvars

# S3 버킷의 이름 설정
bucket_name = "my-static-website-bucket"

# 로컬 시스템에서 업로드할 인덱스 문서 파일의 경로
index_document_path = "./index.html"

# 로컬 시스템에서 업로드할 에러 문서 파일의 경로
error_document_path = "./error.html"

# 환경 설정 (예: dev, prod 등)
environment = "dev"
