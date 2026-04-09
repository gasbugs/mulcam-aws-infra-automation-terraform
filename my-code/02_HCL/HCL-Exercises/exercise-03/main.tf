/*
### 문제 3: 반복문 활용하기

목표: 아래의 요구 사항을 충족하는 HCL 코드를 작성하세요.

1. cities라는 리스트 변수를 선언하고 "Seoul", "Tokyo", "New York" 세 개의 도시를 기본값으로 설정합니다.
2. 각 도시 이름 앞에 "City: "라는 접두사를 추가하여 리스트를 구성하고 출력하세요.
*/

variable "cities" {
  type    = list(string)
  default = ["Seoul", "Tokyo", "New York"]
}

locals {
  city_list = [for city in var.cities : "City: ${city}"]
}

output "city_print" {
  value = local.city_list
}
