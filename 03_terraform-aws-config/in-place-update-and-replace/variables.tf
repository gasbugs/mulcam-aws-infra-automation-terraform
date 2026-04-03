# variables.tf

# AWS 리전 설정
variable "aws_region" {
  description = "리소스를 배포할 AWS 리전"
  type        = string
  default     = "us-east-1"
}

# 사용할 AWS CLI 프로필 설정
variable "aws_profile" {
  description = "AWS CLI에서 사용할 프로필"
  type        = string
  default     = "my-profile"
}

# 배포 환경 설정 (예: dev, staging, prod)
variable "environment" {
  description = "배포 환경 설정 (예: dev, staging, prod)"
  type        = string
  default     = "dev"
}

# EC2 인스턴스 이름 태그
variable "instance_name" {
  description = "EC2 인스턴스의 Name 태그 값"
  type        = string
  default     = "MyEC2Instance"
}

# EC2 인스턴스 유형 설정
# [in-place 업데이트 예시] t3.small → t3.medium 처럼 같은 패밀리 내 변경은 in-place 업데이트됨
# [replace 업데이트 예시] t3.small → c5.large 처럼 다른 패밀리로 변경하면 인스턴스가 replace됨
variable "instance_type" {
  description = "EC2 인스턴스 유형 (in-place 업데이트 가능, 패밀리 변경 시 replace 발생)"
  type        = string
  default     = "t3.small"
  # default   = "c5.large"  # 다른 패밀리로 변경하여 replace 업데이트 실습
}

# AMI 선택: true = Amazon Linux 2023, false = Ubuntu 24.04
# [replace 업데이트 예시] AMI ID가 변경되면 인스턴스가 replace됨
variable "use_amazon_linux" {
  description = "true이면 Amazon Linux 2023 사용, false이면 Ubuntu 24.04 사용 (AMI 변경 시 replace 업데이트)"
  type        = bool
  default     = true
}

# 웹 서버 선택: "httpd" 또는 "nginx"
# [replace 업데이트 실습] 값 변경 시 user_data가 바뀌어 인스턴스가 replace됨
variable "web_server" {
  description = "설치할 웹 서버 종류 - httpd 또는 nginx (변경 시 replace 업데이트 발생)"
  type        = string
  default     = "httpd"

  validation {
    condition     = contains(["httpd", "nginx"], var.web_server)
    error_message = "web_server는 'httpd' 또는 'nginx'만 허용됩니다."
  }
}
