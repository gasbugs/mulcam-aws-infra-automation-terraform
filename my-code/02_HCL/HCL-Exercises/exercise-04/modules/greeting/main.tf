# 모듈의 내용은 1번 문제와 거의 동일 
variable "message_prefix" {
  type = string
}

variable "greeting" {
  type = string
}

output "greeting_output" {
  value = "${var.message_prefix}${var.greeting}"
}
