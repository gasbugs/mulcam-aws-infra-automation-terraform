/*
### 문제 4: 모듈 사용하기

목표: 다음과 같은 요구 사항을 충족하는 HCL 코드를 작성하세요.

1. modules/greeting 디렉토리를 생성하고, greeting을 변수로 받아 인사 메시지를 출력하는 모듈을 작성합니다.
2. message_prefix라는 변수를 추가로 받아 출력할 메시지에 접두사를 추가합니다.
3. 루트 모듈에서 이 모듈을 호출하여 greeting을 "Hello", message_prefix를 "Welcome: "으로 설정하고, 최종 메시지를 출력하세요.
*/

module "greeting" {
  source = "./modules/greeting"

  message_prefix = "Welcome: "
  greeting       = "Hello"
}

output "module_output" {
  value = module.greeting.greeting_output
}
