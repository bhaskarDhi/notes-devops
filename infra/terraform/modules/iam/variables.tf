variable "name" {
  type = string
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repository for the app image"
  type        = string
}

variable "ssm_prefix" {
  description = "SSM Parameter Store path for this environment, e.g. /notes-devops/prod"
  type        = string
}
