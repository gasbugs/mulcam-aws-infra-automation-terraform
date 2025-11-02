output "github_webhook_secret" {
  value = local.github_webhook_secret
}

output "github_webhook_url" {
  value = aws_codepipeline_webhook.github_webhook.url
}

