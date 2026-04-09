# 파일을 로컬에 생성하는 예제
# 파일 생성
resource "local_file" "example" {
  content  = "Hello, Terraform!"              # 파일의 내용 
  filename = "${path.module}/${var.filename}" # 파일의 이름
}


