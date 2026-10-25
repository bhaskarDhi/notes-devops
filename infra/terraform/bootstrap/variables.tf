variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used in resource names and tags"
  type        = string
  default     = "notes-devops"
}

variable "ecr_keep_images" {
  description = "How many tagged images to keep in ECR"
  type        = number
  default     = 15
}
