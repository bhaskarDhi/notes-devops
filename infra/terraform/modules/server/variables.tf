variable "name" {
  description = "Server name, e.g. notes-devops-app"
  type        = string
}

variable "role" {
  description = "Role tag used by Ansible and Prometheus to find the server: app, jenkins or monitoring"
  type        = string
}

variable "ami_id" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "security_group_ids" {
  type = list(string)
}

variable "key_name" {
  description = "EC2 key pair for the admin (your Mac key)"
  type        = string
}

variable "instance_profile" {
  description = "IAM instance profile (the server's permissions)"
  type        = string
}

variable "root_volume_size" {
  description = "Disk size in GB"
  type        = number
  default     = 20
}

variable "user_data" {
  description = "cloud-init configuration run at first boot"
  type        = string
  default     = null
}

variable "metadata_hop_limit" {
  description = "How many network hops the instance metadata (IAM credentials) may travel. 2 lets Docker containers on the server use the IAM role"
  type        = number
  default     = 1
}
