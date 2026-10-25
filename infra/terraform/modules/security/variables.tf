variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "admin_cidr" {
  description = "Your public IP with /32: the only address allowed to SSH to the bastion"
  type        = string
}
