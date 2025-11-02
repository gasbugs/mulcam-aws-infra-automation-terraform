#######################################
# DynamoDB 정보
resource "aws_dynamodb_table" "users_table" {
  name = var.table_name

  # 요금제를 선택 고정된 읽기와 쓰기가 가능하게 하려면 
  # billing 모드를  PROVISIONED 로 하고, read, write_capacity를 활성화하고
  # 요청당 비용을 측정하게 하려면 billing 모드를 PAY_PER_REQUEST로 설정한다. 
  billing_mode = "PAY_PER_REQUEST"
  # read_capacity  = var.read_capacity
  # write_capacity = var.write_capacity
  hash_key  = "UserId"
  range_key = "CreatedAt" # 테이블의 정렬 키로 사용할 속성 추가 (해시 키와 결합)


  attribute {
    name = "UserId"
    type = "S" # String 타입
  }

  attribute {
    name = "CreatedAt"
    type = "S" # 'CreatedAt'은 문자열(String) 타입으로 정렬 키에 사용
  }

  # 글로벌 보조 인덱스 설정 (Global Secondary Index)
  global_secondary_index {
    name            = "UsernameIndex" # 인덱스의 이름 설정
    hash_key        = "Username"      # 인덱스의 해시 키로 사용할 속성
    projection_type = "ALL"           # 인덱스에서 모든 테이블 속성을 가져오도록 설정
  }

  attribute {
    name = "Username"
    type = "S" # 'Username'은 문자열(String) 타입으로 보조 인덱스의 해시 키에 사용
  }

  point_in_time_recovery {
    enabled = true
  }
}


#######################################
# DynamoDB 백업
# 백업을 저장할 Vault 생성
resource "aws_backup_vault" "dynamodb_backup_vault" {
  name = "dynamodb-backup-vault"
}

# 백업 계획 생성 (백업 주기와 보관 주기 정의)
resource "aws_backup_plan" "dynamodb_backup_plan" {
  name = "dynamodb-backup-plan"

  rule {
    rule_name         = "daily-dynamodb-backup"
    target_vault_name = aws_backup_vault.dynamodb_backup_vault.name
    schedule          = "cron(40 * * * ? *)" # 매시 10분에 백업 생성 (UTC) (현재 시간에서 약 10분 후로 설정)
    lifecycle {
      delete_after = 30 # 30일 동안 백업을 보관한 후 삭제
    }
  }
}

# DynamoDB 테이블을 백업 대상으로 선택
resource "aws_backup_selection" "dynamodb_backup_selection" {
  iam_role_arn = aws_iam_role.backup_role.arn
  name         = "dynamodb-backup-selection"
  plan_id      = aws_backup_plan.dynamodb_backup_plan.id

  # 백업할 DynamoDB 테이블의 ARN
  resources = [
    "arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${aws_dynamodb_table.users_table.name}"
  ]
}

# AWS Backup을 위한 IAM 역할 생성
resource "aws_iam_role" "backup_role" {
  name = "backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# IAM 역할에 백업 권한 부여
resource "aws_iam_role_policy_attachment" "backup_policy" {
  role       = aws_iam_role.backup_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# 현재 AWS 리전 및 계정 정보
data "aws_region" "current" {}

data "aws_caller_identity" "current" {}
