variable "aws_profile" {
  description = "AWS CLI 프로파일 이름 — ~/.aws/config 에 정의된 named profile"
  type        = string
  default     = "my-profile"
}

variable "aws_region" {
  description = "리소스를 배포할 AWS 리전"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "배포 환경 구분자 — 리소스 이름과 태그에 사용"
  type        = string
  default     = "dev"
}

variable "instance_type" {
  description = "EC2 인스턴스 타입 — 도커 실습용이므로 t3.micro 사용"
  type        = string
  default     = "t3.micro"
}

variable "project_name" {
  description = "프로젝트 이름 — 리소스 이름 접두사와 태그에 사용"
  type        = string
  default     = "docker-basics"
}

variable "root_volume_size" {
  description = "루트 EBS 볼륨 크기(GB) — 도커 이미지 저장 공간 확보를 위해 50GB 권장"
  type        = number
  default     = 50
}
