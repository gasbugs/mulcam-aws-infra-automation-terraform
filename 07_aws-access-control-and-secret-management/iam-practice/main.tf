#####################################################################
# 1)
# S3 읽기/쓰기 정책 생성 #IAM #S3 #ReadWritePolicy
resource "aws_iam_policy" "s3_rw_policy" {
  name        = "S3ReadWritePolicy"                                                 # 정책 이름
  description = "Policy for project_member to access S3 bucket project-data-bucket" # 정책 설명
  policy = jsonencode({                                                             # 정책을 JSON 형식으로 인코딩
    "Version" = "2012-10-17",
    "Statement" = [
      {
        "Effect" = "Allow", # 허용 정책
        "Action" = [        # 허용할 액션 목록
          "s3:GetObject",   # S3 객체 읽기 권한
          "s3:PutObject"    # S3 객체 쓰기 권한
        ],
        "Resource" = "arn:aws:s3:::project-data-bucket/*" # 대상 S3 버킷과 모든 객체
      }
    ]
  })
}


# IAM 유저 생성
resource "aws_iam_user" "project_member" {
  name = "project_member"
}

resource "aws_iam_user_policy_attachment" "project_member_policy_attach" {
  user       = aws_iam_user.project_member.name
  policy_arn = aws_iam_policy.s3_rw_policy.arn
}

# 생성한 유저에 대한 Access Key 생성 (프로그래밍적 접근을 위해 사용)
resource "aws_iam_access_key" "example_user_key" {
  user = aws_iam_user.project_member.name
}


#####################################################################
# 2)
resource "aws_iam_user" "operating_user" {
  name = "operating_user"
}

# EC2 상태 조회를 위한 IAM 역할 생성 #IAM #Role #EC2
resource "aws_iam_role" "dev_ec2_status_viewer" {
  name = "DevEC2StatusViewer" # 역할 이름

  assume_role_policy = jsonencode({ # Assume Role 정책 설정
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow", # 역할 위임 허용
        "Principal" : {
          "AWS" : "${aws_iam_user.operating_user.arn}" # 역할을 사용할 계정 ID (운영 계정)
        },
        "Action" : "sts:AssumeRole" # sts:AssumeRole 액션 허용
      }
    ]
  })
}


# EC2 인스턴스 상태 조회 권한 정책 생성 #IAM #Policy #EC2
resource "aws_iam_policy" "ec2_status_view_policy" {
  name        = "EC2DescribeInstancesPolicy"         # 정책 이름
  description = "Allows viewing EC2 instance status" # 정책 설명
  policy = jsonencode({                              # 정책을 JSON 형식으로 인코딩
    "Version" = "2012-10-17",
    "Statement" = [
      {
        "Effect"   = "Allow",                 # 허용 정책
        "Action"   = "ec2:DescribeInstances", # EC2 인스턴스 상태 조회 액션
        "Resource" = "*"                      # 모든 리소스에 대해 적용
      }
    ]
  })
}

# EC2 상태 조회 역할에 정책 연결 #IAM #RolePolicyAttachment
resource "aws_iam_role_policy_attachment" "dev_ec2_status_attach" {
  role       = aws_iam_role.dev_ec2_status_viewer.name   # 역할 이름
  policy_arn = aws_iam_policy.ec2_status_view_policy.arn # 정책 ARN
}
