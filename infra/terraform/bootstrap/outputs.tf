output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "region" {
  value = var.region
}

output "state_bucket" {
  description = "S3 bucket that stores Terraform state"
  value       = aws_s3_bucket.tfstate.bucket
}

output "ecr_repository_url" {
  description = "Where Jenkins pushes and the app server pulls images"
  value       = aws_ecr_repository.app.repository_url
}
