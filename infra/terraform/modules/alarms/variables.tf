variable "name" {
  type = string
}

variable "alert_email" {
  description = "Email that receives CloudWatch alarms (you must confirm the subscription email)"
  type        = string
}

variable "db_identifier" {
  type = string
}

variable "instance_ids" {
  description = "Map of server name => EC2 instance id"
  type        = map(string)
}
