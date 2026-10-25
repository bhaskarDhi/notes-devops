variable "name" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "ssm_prefix" {
  description = "Where to store the connection settings in SSM, e.g. /notes-devops/prod"
  type        = string
}

variable "db_name" {
  type    = string
  default = "notes"
}

variable "db_username" {
  type    = string
  default = "notes_admin"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "engine_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "16"
}

variable "allocated_storage" {
  description = "Disk size in GB"
  type        = number
  default     = 20
}
