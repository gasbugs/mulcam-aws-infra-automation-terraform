##############################################################################
# [outputs.tf] terraform apply 완료 후 화면에 출력할 주요 정보
#
# Output은 배포가 끝난 뒤 사용자가 바로 참고해야 할 값들을 터미널에 출력합니다.
# 이 파일에서 출력하는 것:
#   - pipeline_arn / pipeline_name: 파이프라인 식별자 (CLI 실행 시 필요)
#   - s3_bucket_name: 빌드 로그 확인용 버킷 이름
#   - codecommit_clone_url_http/ssh: 소스 코드 push 주소
#   - base_ami_id: 레시피가 사용하는 베이스 AMI ID
#   - start_pipeline_command: 파이프라인을 수동으로 트리거하는 완성된 CLI 명령어
#   - push_source_command: 소스를 CodeCommit에 최초 push하는 명령어 안내
##############################################################################

# 배포 완료 후 확인에 필요한 주요 값 출력
output "pipeline_arn" {
  description = "Image Builder 파이프라인 ARN — AWS CLI로 빌드를 수동 트리거할 때 사용"
  value       = aws_imagebuilder_image_pipeline.spring_boot.arn
}

output "pipeline_name" {
  description = "Image Builder 파이프라인 이름"
  value       = aws_imagebuilder_image_pipeline.spring_boot.name
}

output "s3_bucket_name" {
  description = "빌드 로그가 저장되는 S3 버킷 이름"
  value       = aws_s3_bucket.image_builder_artifacts.id
}

output "codecommit_clone_url_http" {
  description = "소스 코드를 push할 CodeCommit HTTPS 클론 URL"
  value       = aws_codecommit_repository.spring_app.clone_url_http
}

output "codecommit_clone_url_ssh" {
  description = "소스 코드를 push할 CodeCommit SSH 클론 URL"
  value       = aws_codecommit_repository.spring_app.clone_url_ssh
}

output "base_ami_id" {
  description = "레시피 베이스로 사용된 Amazon Linux 2023 AMI ID"
  value       = data.aws_ami.al2023.id
}

output "start_pipeline_command" {
  description = "파이프라인을 수동으로 실행하는 AWS CLI 명령어"
  value       = "aws imagebuilder start-image-pipeline-execution --image-pipeline-arn ${aws_imagebuilder_image_pipeline.spring_boot.arn} --profile ${var.aws_profile} --region ${var.aws_region}"
}

output "push_source_command" {
  description = "소스 코드를 CodeCommit에 최초 push하는 명령어 안내"
  value       = "push-to-codecommit.sh 스크립트를 실행하거나: cd ../packer-for-javaspring && git init && git remote add origin ${aws_codecommit_repository.spring_app.clone_url_http} && git add pom.xml src/ && git commit -m 'init' && git push -u origin main"
}
