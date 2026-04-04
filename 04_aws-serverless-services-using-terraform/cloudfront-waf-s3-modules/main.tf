# 이 파일은 전체 인프라의 뼈대입니다.
# S3(파일 저장소)와 CloudFront(전 세계 빠른 배포)+WAF(보안 필터) 두 모듈을 조합해서 웹사이트를 구성합니다.

# S3 모듈 호출 — 웹 파일을 저장할 버킷과 파일 업로드를 담당합니다.
module "s3" {
  source = "./modules/s3"

  bucket_name         = var.bucket_name         # 버킷 기본 이름 (실제 이름에는 랜덤 숫자가 붙음)
  environment         = var.environment         # 환경 구분 태그 (dev / prod)
  index_document      = var.index_document      # 첫 화면 파일 이름 (예: index.html)
  error_document      = var.error_document      # 에러 화면 파일 이름 (예: error.html)
  index_document_path = var.index_document_path # 로컬 인덱스 파일 경로
  error_document_path = var.error_document_path # 로컬 에러 파일 경로
}

# CloudFront + WAF 모듈 호출
# CloudFront: 전 세계에 캐시 서버를 두어 빠르게 웹사이트를 전달하는 서비스
# WAF(Web Application Firewall): SQL 인젝션 등 악의적인 요청을 차단하는 보안 서비스
module "cloudfront" {
  source = "./modules/cloudfront"

  bucket_name        = var.bucket_name              # WAF/CloudFront 리소스 이름에 사용할 버킷 이름
  bucket_id          = module.s3.bucket_id          # S3 버킷 ID — CloudFront 오리진으로 연결
  bucket_domain_name = module.s3.bucket_domain_name # S3 지역 엔드포인트 — OAC 방식에 필수
  bucket_arn         = module.s3.bucket_arn         # S3 버킷 ARN — 버킷 정책에서 CloudFront만 허용할 때 사용
  index_document     = var.index_document           # CloudFront 기본 루트 오브젝트 (예: index.html)
  error_document     = var.error_document           # 에러 발생 시 보여줄 페이지 (예: error.html)
}
