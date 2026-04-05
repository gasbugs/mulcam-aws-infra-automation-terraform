# 기본값이 없는 필수 설정값만 지정 (나머지는 variables.tf의 기본값 사용)
aws_region  = "us-east-1"
aws_profile = "my-profile"

# 복원할 스냅샷 ID (스냅샷 생성 시마다 업데이트 필요)
db_cluster_snapshot_identifier = "tf-snapshot-2026-04-05t08-40-01z"
