# [1. 테라폼 도구 설정]
# 이 코드를 실행하는 '테라폼'이라는 도구가 어떤 버전이어야 하는지, 
# 그리고 아마존 클라우드(AWS)와 연결하기 위한 플러그인이 필요한지 정의합니다.
terraform {
  required_version = ">=1.13.4" # 테라폼 프로그램의 최소 버전
  required_providers {
    aws = {
      source  = "hashicorp/aws" # AWS 전용 도구 세트를 가져옴
      version = "~> 6.0"         # 도구 세트의 버전 범위
    }
  }
}

# [2. AWS 연결 설정]
# 내 컴퓨터에서 AWS 서버에 접속할 때 필요한 기본 정보들을 적습니다.
provider "aws" {
  region  = "us-east-1"    # 미국 동부(버지니아 북부) 지역의 데이터센터를 사용하겠다는 뜻
  profile = "my-profile"   # 미리 설정해둔 내 AWS 계정 이름 (로그인 정보 대신 사용)
}

# [3. 운영체제 설치 이미지 찾기]
# 컴퓨터를 만들려면 윈도우나 리눅스 같은 운영체제가 필요한데, 
# AWS에서 제공하는 최신 리눅스(Amazon Linux 2023) 이미지를 자동으로 찾아오게 시킵니다.
data "aws_ami" "al2023" {
  most_recent = true     # 가장 최근에 나온 버전을 선택
  owners      = ["amazon"] # 아마존에서 공식적으로 만든 것만 찾음

  filter {
    name   = "name"
    values = ["al2023-ami-*"] # 이름이 al2023으로 시작하는 파일을 찾음
  }

  filter {
    name   = "architecture"
    values = ["x86_64"] # 일반적인 64비트 컴퓨터 규격을 선택
  }
}

# [4. 실제 가상 컴퓨터(서버) 만들기]
# 위에서 찾은 정보를 바탕으로 AWS 클라우드 안에 가상 컴퓨터를 한 대 생성합니다.
resource "aws_instance" "example" {
  ami           = data.aws_ami.al2023.id # 위(3번)에서 찾아낸 운영체제 이미지를 설치함
  instance_type = "t3.micro"            # 컴퓨터의 사양 (저렴하고 기본적인 성능의 모델)
}
