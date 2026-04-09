##############################################################################
# [variables.tf] 이 프로젝트 전체에서 사용하는 입력 변수 모음
#
# Variable은 코드에 값을 직접 쓰지 않고 외부에서 주입할 수 있게 합니다.
# 이 파일에서 정의하는 것:
#   - aws_region: 리소스를 생성할 AWS 리전 (기본값: us-east-1)
#   - aws_profile: 사용할 AWS CLI 프로파일 이름 (기본값: my-profile)
#   - environment: 리소스 이름 접두사 — dev/prod 환경을 구분 (기본값: dev)
#   - ami_name_prefix: 생성될 AMI 이름의 앞부분 (기본값: spring-boot-app-ami)
#   - recipe_version: Image Recipe 버전 — 컴포넌트 변경 시 반드시 올려야 함
#   - codecommit_repo_name: 생성할 CodeCommit 저장소 이름
##############################################################################

# 이 프로젝트에서 사용하는 입력 변수 모음
variable "aws_region" {
  description = "AWS 리소스를 생성할 리전"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI에 설정된 Named Profile 이름"
  type        = string
  default     = "my-profile"
}

variable "environment" {
  description = "리소스 이름 접두사로 사용할 환경 구분자 (예: dev, prod)"
  type        = string
  default     = "dev"
}

variable "ami_name_prefix" {
  description = "완성된 AMI 이름의 앞부분 — 뒤에 빌드 날짜가 자동으로 붙음"
  type        = string
  default     = "spring-boot-app-ami"
}

variable "recipe_version" {
  description = "Image Recipe 버전 — 컴포넌트를 수정할 때마다 올려야 함 (시맨틱 버전)"
  type        = string
  default     = "1.0.3"
}

variable "codecommit_repo_name" {
  description = "소스 코드를 저장할 CodeCommit 저장소 이름"
  type        = string
  default     = "spring-boot-app"
}
