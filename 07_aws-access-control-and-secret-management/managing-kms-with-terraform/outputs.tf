output "bucket_name" {
  description = "The name of the created S3 bucket"
  value       = aws_s3_bucket.example_bucket.bucket
}

output "kms_key_arn" {
  description = "The ARN of the KMS key used for encryption"
  value       = aws_kms_key.s3_encryption_key.arn
}

output "ec2_instance_id" {
  description = "The ID of the created EC2 instance"
  value       = aws_instance.example_ec2.id
}

output "ec2_public_ip" {
  description = "The public IP address of the created EC2 instance"
  value       = aws_instance.example_ec2.public_ip
}

output "s3_access_policy_arn" {
  description = "The ARN of the IAM policy allowing EC2 to access S3"
  value       = aws_iam_policy.ec2_s3_kms_policy.arn
}

output "ec2_ssh_command" {
  description = "The SSH command to connect to the EC2 instance"
  value       = "ssh -i <path_to_private_key> ec2-user@${aws_instance.example_ec2.public_ip}"
}
