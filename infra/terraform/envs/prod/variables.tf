variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "notes-devops"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.11.0/24", "10.20.12.0/24"]
}

variable "admin_cidr" {
  description = "Your public IP with /32 (curl -s https://checkip.amazonaws.com)"
  type        = string
}

variable "alert_email" {
  description = "Email for CloudWatch alarms"
  type        = string
}

variable "public_key_path" {
  description = "Your SSH public key on the Mac"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "jenkins_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "app_instance_type" {
  type    = string
  default = "t3.small"
}

variable "monitoring_instance_type" {
  type    = string
  default = "t3.small"
}
