###############
# Secret Manager를 활용한 RDS 패스워드와 교체를 위한 람다 설정
# KMS 키 생성 (시크릿 암호화에 사용)
resource "aws_kms_key" "example_key" {
  description             = var.kms_description
  deletion_window_in_days = 10
}

resource "random_integer" "secret_suffix" {
  min = 1000
  max = 9999
}

# AWS Secrets Manager 시크릿 생성
resource "aws_secretsmanager_secret" "example_secret" {
  name        = "${var.secret_name}-${random_integer.secret_suffix.result}"
  description = var.secret_description
  kms_key_id  = aws_kms_key.example_key.arn
}

resource "random_string" "example" {
  length  = 16    # 생성할 문자열의 길이
  special = false # 특수문자 포함 여부
  upper   = true  # 대문자 포함 여부
  lower   = true  # 소문자 포함 여부
  numeric = true  # 숫자 포함 여부
}


# AWS Secrets Manager 시크릿 버전 생성 (초기 값)
resource "aws_secretsmanager_secret_version" "example_secret_version" {
  secret_id = aws_secretsmanager_secret.example_secret.id
  secret_string = jsonencode({
    "username" = var.secret_username
    "password" = resource.random_string.example.result
  })
}

# ZIP 파일 생성 (lambda_function.zip)
data "archive_file" "rotate_secret" {
  type = "zip" # ZIP 파일 형식

  source_dir  = "${path.module}/lambda"            # ZIP으로 압축할 소스 디렉터리
  output_path = "${path.module}/rotate_secret.zip" # 생성된 ZIP 파일 경로
}

# Lambda 함수 생성
resource "aws_lambda_function" "rotate_secret" {
  function_name = var.lambda_function_name
  role          = aws_iam_role.lambda_secrets_manager_role.arn
  handler       = "rotate_secret.lambda_handler"
  runtime       = "python3.8"

  # Lambda 코드 (Zip 파일로 저장됨)
  filename         = data.archive_file.rotate_secret.output_path
  source_code_hash = filebase64sha256(data.archive_file.rotate_secret.output_path)

  environment {
    variables = {
      SECRET_ID = aws_secretsmanager_secret.example_secret.id
    }
  }
}

# IAM 역할 생성 (Lambda 함수에서 Secrets Manager 접근 허용)
resource "aws_iam_role" "lambda_secrets_manager_role" {
  name = "lambda-secrets-manager-role"

  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "lambda.amazonaws.com"
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
}

# IAM 정책 생성 및 역할에 부착 (Secrets Manager 및 CloudWatch Logs 접근 허용)
resource "aws_iam_policy" "lambda_secrets_manager_policy" {
  name        = "lambda-secrets-manager-policy"
  description = "Policy to allow Lambda to access Secrets Manager and CloudWatch Logs"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "secretsmanager:PutSecretValue",
          "secretsmanager:GetSecretValue"
        ],
        "Resource" : aws_secretsmanager_secret.example_secret.arn
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        "Resource" : "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# IAM 정책을 IAM 역할에 부착
resource "aws_iam_role_policy_attachment" "attach_lambda_policy" {
  role       = aws_iam_role.lambda_secrets_manager_role.name
  policy_arn = aws_iam_policy.lambda_secrets_manager_policy.arn
}

# KMS에 접근할 수 있는 권한 추가
resource "aws_iam_policy" "lambda_kms_policy" {
  name        = "LambdaKMSAccessPolicy"
  description = "Policy to allow Lambda to use the KMS key for Secrets Manager"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:ReEncrypt*"
        ],
        "Resource" : aws_kms_key.example_key.arn
      }
    ]
  })
}

# Lambda 역할에 KMS 접근 정책 부착
resource "aws_iam_role_policy_attachment" "attach_kms_policy" {
  role       = aws_iam_role.lambda_secrets_manager_role.name
  policy_arn = aws_iam_policy.lambda_kms_policy.arn
}

# Secrets Manager 시크릿 로테이션 설정
resource "aws_secretsmanager_secret_rotation" "example" {
  secret_id           = aws_secretsmanager_secret.example_secret.id
  rotation_lambda_arn = aws_lambda_function.rotate_secret.arn


  rotation_rules {
    automatically_after_days = 30 # 30일마다 시크릿 로테이션
  }
}

# Secrets Manager가 Lambda 함수를 호출할 수 있도록 권한 부여
resource "aws_lambda_permission" "allow_secrets_manager" {
  statement_id  = "AllowSecretsManagerInvocation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotate_secret.function_name
  principal     = "secretsmanager.amazonaws.com"
}
