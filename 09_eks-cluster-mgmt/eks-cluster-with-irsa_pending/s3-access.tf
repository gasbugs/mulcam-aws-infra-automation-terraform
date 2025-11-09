#########################################################
# S3 배포

# S3 버킷 생성
resource "aws_s3_bucket" "my_bucket" {
  bucket = "my-private-s3-bucket-${lower(random_string.suffix.result)}" # 버킷 이름을 설정. 무작위 문자열을 추가하여 고유성을 보장

  force_destroy = true # 버킷 삭제 시 버킷 내 객체들도 함께 삭제 (강제 삭제)
}

# S3 Gateway VPC Endpoint 생성
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id                    # VPC ID를 가져와 설정
  service_name      = "com.amazonaws.${var.aws_region}.s3" # AWS S3의 서비스 이름을 리전에 맞춰 설정
  vpc_endpoint_type = "Gateway"                            # S3 엔드포인트의 타입을 Gateway로 설정 (S3는 Gateway 타입을 사용)

  route_table_ids = module.vpc.private_route_table_ids # VPC의 프라이빗 라우팅 테이블과 연결
}

#########################################################
# ServiceAccount 구성 및 파드 생성

locals {
  namespace = "s3-access"     # S3 접근을 위한 네임스페이스
  sa_name   = "s3-access-sa"  # 서비스 어카운트 이름 정의
  pod_name  = "s3-access-app" # 파드 이름 정의
}

# S3 접근을 위한 IAM 역할과 OIDC를 활용한 IRSA (IAM Roles for Service Accounts) 모듈 정의
module "irsa-s3-access" {
  source                        = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version                       = "4.20"
  create_role                   = true                                                          # 새로운 IAM 역할 생성
  role_name                     = "AmazonEKSS3AccessRole-${module.eks.cluster_name}"            # IAM 역할 이름에 EKS 클러스터 이름 추가
  provider_url                  = module.eks.oidc_provider                                      # EKS 클러스터의 OIDC 프로바이더 URL 설정
  role_policy_arns              = ["arn:aws:iam::aws:policy/AmazonS3FullAccess"]                # S3에 대한 전체 액세스 권한을 부여하는 정책 연결
  oidc_fully_qualified_subjects = ["system:serviceaccount:${local.namespace}:${local.sa_name}"] # OIDC에서 인증된 주체(Service Account)에 대해 정책 적용
}

# Kubernetes 네임스페이스 생성 (S3 접근용)
resource "kubernetes_namespace_v1" "s3-access" {
  metadata {
    name = local.namespace # 네임스페이스 이름 설정
  }
  depends_on = [null_resource.update_kubeconfig] # 네임스페이스 생성을 EKS kubeconfig 업데이트 후에 실행
}

# S3 접근용 서비스 어카운트 생성
resource "kubernetes_service_account_v1" "s3_access_sa" {
  metadata {
    name      = local.sa_name                                      # 서비스 어카운트 이름 설정
    namespace = kubernetes_namespace_v1.s3-access.metadata[0].name # 네임스페이스 설정
    annotations = {
      "eks.amazonaws.com/role-arn" = module.irsa-s3-access.iam_role_arn # EKS 클러스터의 OIDC와 연결된 IAM 역할 주입
    }
  }
  automount_service_account_token = true # 서비스 어카운트 토큰 자동 마운트 활성화
}

# S3 접근을 위한 파드 생성
resource "kubernetes_pod" "s3_access_pod" {
  metadata {
    name      = local.pod_name                                     # 파드 이름 설정
    namespace = kubernetes_namespace_v1.s3-access.metadata[0].name # 네임스페이스 설정
  }
  spec {
    service_account_name = kubernetes_service_account_v1.s3_access_sa.metadata[0].name # 파드가 사용할 서비스 어카운트 설정

    container {
      name    = "aws-cli-container"   # 컨테이너 이름 설정
      image   = "gasbugs/aws-cli"     # AWS CLI가 설치된 Docker 이미지 사용
      command = ["sleep", "infinity"] # 파드가 무한 대기 상태에 있도록 설정
    }
  }
}

# s3에 접근하는 코드 예제
# kubectl exec -n s3-access s3-access-app -- aws s3 cp /etc/passwd s3://my-private-s3-bucket-h83oarqr/test_passwd.txt
