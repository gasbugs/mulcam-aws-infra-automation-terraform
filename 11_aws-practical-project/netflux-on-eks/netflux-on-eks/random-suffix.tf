# 랜덤한 숫자 생성 (bucket 이름에 사용)
resource "random_integer" "bucket_suffix" {
  min = 1000 # 최소 값
  max = 9999 # 최대 값
}
