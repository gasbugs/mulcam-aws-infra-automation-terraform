# variables.tf
# 이 프로젝트에서 사용하는 설정값들을 변수로 정의합니다.
# 변수를 사용하면 같은 코드를 환경(개발/운영)에 따라 다르게 적용할 수 있습니다.

# AWS 리소스를 생성할 지역(리전)을 지정합니다.
# AWS는 전 세계 여러 데이터센터를 운영하며, 리전은 그 위치를 나타냅니다.
variable "aws_region" {
  description = "리소스를 생성할 AWS 리전 (예: us-east-1은 미국 동부)"
  type        = string
  default     = "us-east-1"
}

# 내 컴퓨터에 저장된 AWS 인증 정보 중 어떤 프로파일을 사용할지 지정합니다.
# ~/.aws/config 또는 ~/.aws/credentials 파일에 정의된 이름입니다.
variable "aws_profile" {
  description = "사용할 AWS CLI 프로파일 이름 (~/.aws/config에 저장된 인증 정보)"
  type        = string
  default     = "my-profile"
}

# 생성할 S3 버킷의 기본 이름입니다.
# S3 버킷 이름은 전 세계에서 유일해야 하므로 main.tf에서 랜덤 숫자를 뒤에 붙입니다.
variable "bucket_name" {
  description = "S3 버킷의 기본 이름 (실제 이름에는 중복 방지를 위해 랜덤 숫자가 추가됩니다)"
  type        = string
  default     = "my-static-website-bucket"
}

# 웹사이트의 메인 페이지 파일 이름입니다.
# 브라우저에서 도메인 주소만 입력했을 때 가장 먼저 보여줄 파일입니다.
variable "index_document" {
  description = "웹사이트 첫 화면에 보여줄 파일 이름 (예: index.html)"
  type        = string
  default     = "index.html"
}

# 존재하지 않는 페이지에 접근했을 때 보여줄 오류 페이지 파일 이름입니다.
variable "error_document" {
  description = "페이지를 찾을 수 없을 때 보여줄 오류 파일 이름 (예: error.html)"
  type        = string
  default     = "error.html"
}

# 웹사이트 파일(HTML 등)이 저장된 로컬 디렉토리 경로입니다.
# Terraform 코드(.tf 파일)와 웹사이트 파일을 분리해 관리하기 위해 별도 디렉토리를 사용합니다.
# 파일을 추가하거나 경로를 바꿀 때 이 변수 하나만 수정하면 됩니다.
variable "www_dir" {
  description = "웹사이트 파일(HTML, CSS, JS 등)이 들어있는 로컬 디렉토리 경로"
  type        = string
  default     = "./www"
}

# 배포 환경을 구분하는 태그입니다.
# 같은 AWS 계정에 개발/운영 환경을 함께 운영할 때 리소스를 구분하는 데 사용합니다.
variable "environment" {
  description = "배포 환경 구분 태그 (예: dev=개발, staging=스테이징, prod=운영)"
  type        = string
  default     = "dev"
}
