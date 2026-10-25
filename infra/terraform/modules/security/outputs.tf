output "jenkins_sg_id" {
  value = aws_security_group.jenkins.id
}

output "app_sg_id" {
  value = aws_security_group.app.id
}

output "monitoring_sg_id" {
  value = aws_security_group.monitoring.id
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}
