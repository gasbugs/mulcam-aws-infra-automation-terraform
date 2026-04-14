variable "aws_region" {
  description = "Region for AWS"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS 클러스터에 사용할 Kubernetes 버전 — 업그레이드 시 이 값만 변경하세요"
  type        = string
  default     = "1.35"
}
