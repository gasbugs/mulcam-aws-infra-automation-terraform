# 출력값 정의 — EC2 접속 및 리소스 확인에 필요한 정보

output "bucket_name" {
  description = "생성된 S3 버킷의 이름"
  value       = aws_s3_bucket.example_bucket.bucket
}

output "kms_key_arn" {
  description = "S3 및 EC2 볼륨 암호화에 사용된 KMS 키의 ARN"
  value       = aws_kms_key.s3_encryption_key.arn
}

output "ec2_instance_id" {
  description = "생성된 EC2 인스턴스의 ID"
  value       = aws_instance.example_ec2.id
}

output "ec2_public_ip" {
  description = "생성된 EC2 인스턴스의 공인 IP 주소"
  value       = aws_instance.example_ec2.public_ip
}

output "s3_access_policy_arn" {
  description = "EC2가 S3에 접근할 수 있도록 허용하는 IAM 정책의 ARN"
  value       = aws_iam_policy.ec2_s3_kms_policy.arn
}

output "ec2_ssh_command" {
  description = "EC2 인스턴스에 SSH로 접속하는 명령어 (ec2-key.pem 파일 사용)"
  value       = "ssh -i ec2-key.pem ec2-user@${aws_instance.example_ec2.public_ip}"
}

# EC2 SSH 접속용 프라이빗 키 — terraform output -raw private_key_pem > ec2-key.pem 으로 저장
output "private_key_pem" {
  description = "EC2 SSH 접속용 프라이빗 키 PEM 내용 (terraform output -raw private_key_pem > key.pem으로 저장)"
  value       = tls_private_key.ec2_key.private_key_pem
  sensitive   = true
}
