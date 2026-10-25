output "app_instance_profile" {
  value = aws_iam_instance_profile.app.name
}

output "jenkins_instance_profile" {
  value = aws_iam_instance_profile.jenkins.name
}

output "monitoring_instance_profile" {
  value = aws_iam_instance_profile.monitoring.name
}

output "app_role_name" {
  value = aws_iam_role.app.name
}

output "jenkins_role_name" {
  value = aws_iam_role.jenkins.name
}

output "monitoring_role_name" {
  value = aws_iam_role.monitoring.name
}
