# ECR 모듈 구성
module "ecr" {
  source  = "terraform-aws-modules/ecr/aws" # 공식 ECR 모듈 소스 경로
  version = "2.3.0"                         # 사용할 모듈 버전

  repository_name = "my-private-ecr" # 생성할 ECR 리포지토리의 이름
  repository_type = "private"        # 리포지토리 유형: 프라이빗 리포지토리

  tags = {
    Environment = "production" # 환경 태그 (프로덕션)
    Project     = "my-app"     # 프로젝트 이름 태그
  }

  repository_image_tag_mutability = "MUTABLE" # 이미지 태그 변경을 허용 (MUTABLE)
  repository_image_scan_on_push   = true      # 이미지 푸시 시 자동 스캔 활성화
  repository_encryption_type      = "AES256"  # 리포지토리 암호화 유형 (AES256)

  repository_force_delete = true

  # ECR 리포지토리의 이미지 라이프사이클 정책 설정
  repository_lifecycle_policy = <<EOT
  {
    "rules": [
      {
        "rulePriority": 1,  
        "description": "Retain only the last 10 images", 
        "selection": {
          "tagStatus": "any",
          "countType": "imageCountMoreThan",
          "countNumber": 10 
        },
        "action": {
          "type": "expire" 
        }
      }
    ]
  }
  EOT
}

# ECR용 VPC 엔드포인트 보안 그룹 설정
resource "aws_security_group" "ecr_vpce_sg" {
  vpc_id = module.vpc.vpc_id # VPC ID 연결 (VPC 내에서만 접근)

  ingress {
    from_port   = 443             # HTTPS 포트
    to_port     = 443             # HTTPS 포트
    protocol    = "tcp"           # TCP 프로토콜 사용
    cidr_blocks = ["10.0.0.0/16"] # VPC 내의 IP 대역에서만 접근 허용
  }

  egress {
    from_port   = 0             # 모든 포트 허용
    to_port     = 0             # 모든 포트 허용
    protocol    = "-1"          # 모든 프로토콜 허용
    cidr_blocks = ["0.0.0.0/0"] # 모든 외부로의 트래픽 허용
  }

  tags = {
    Name = "ecr-vpce-sg" # 보안 그룹의 이름 태그
  }
}

# ECR API를 위한 VPC 엔드포인트
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id       = module.vpc.vpc_id                         # 연결할 VPC ID
  service_name = "com.amazonaws.${var.aws_region}.ecr.api" # ECR API 엔드포인트 서비스

  vpc_endpoint_type  = "Interface"                         # 엔드포인트 유형: 인터페이스 엔드포인트
  subnet_ids         = module.vpc.public_subnets           # 퍼블릭 서브넷에서 접근 가능
  security_group_ids = [aws_security_group.ecr_vpce_sg.id] # 보안 그룹 연결

  private_dns_enabled = true # VPC 내에서 프라이빗 DNS 사용
}

# ECR 도커 레지스트리를 위한 VPC 엔드포인트
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id       = module.vpc.vpc_id                         # 연결할 VPC ID
  service_name = "com.amazonaws.${var.aws_region}.ecr.dkr" # ECR 도커 레지스트리 엔드포인트 서비스

  vpc_endpoint_type  = "Interface"                         # 엔드포인트 유형: 인터페이스 엔드포인트
  subnet_ids         = module.vpc.private_subnets          # 프라이빗 서브넷에서 접근 가능
  security_group_ids = [aws_security_group.ecr_vpce_sg.id] # 보안 그룹 연결

  private_dns_enabled = true # VPC 내에서 프라이빗 DNS 사용
}
