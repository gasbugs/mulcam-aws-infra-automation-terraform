/*
### 문제 2: 조건문 활용하기

목표: 다음 요구 사항을 충족하는 HCL 코드를 작성하세요.

1. is_day라는 변수를 선언하고, 기본값을 true로 설정합니다.
2. is_day의 값에 따라 greeting 변수의 값을 다르게 설정하세요. true일 때는 "Good day!", false일 때는 "Good night!"가 되도록 합니다.
*/

variable "is_day" {
  type    = bool
  default = false
}

locals {
  greeting = var.is_day ? "Good day!" : "Good night!"
}

output "greeting_output" {
  value = local.greeting
}
