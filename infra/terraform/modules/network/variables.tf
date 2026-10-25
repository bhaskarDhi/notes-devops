variable "name" {
  description = "Name prefix for resources"
  type        = string
}

variable "vpc_cidr" {
  description = "IP range of the VPC"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "IP ranges of the public subnets (one per availability zone)"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "IP ranges of the private subnets (one per availability zone)"
  type        = list(string)
}
