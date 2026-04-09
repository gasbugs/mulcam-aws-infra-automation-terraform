/*
### 문제 1: 변수와 출력값 사용하기

기본적인 변수를 선언하고 출력하는 문제입니다.

목표: 아래의 요구 사항을 충족하는 HCL 코드를 작성하세요.

1. greeting이라는 변수를 선언하고 기본값을 "Hello, Terraform!"으로 설정합니다.
2. 출력값으로 "The greeting message is: <greeting>"라는 문구를 표시하세요.
*/

variable "greeting" {
  type    = string
  default = "Hello, Terraform!"
}

output "greeting_output" {
  value = "The greeting message is: ${var.greeting}"
}

