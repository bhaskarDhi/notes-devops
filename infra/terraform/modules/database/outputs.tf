output "db_identifier" {
  value = aws_db_instance.this.identifier
}

output "endpoint" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}
