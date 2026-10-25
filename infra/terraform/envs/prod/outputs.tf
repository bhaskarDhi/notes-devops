locals {
  jenkins_dash = replace(module.jenkins.public_ip, ".", "-")
  app_dash     = replace(module.app.public_ip, ".", "-")
}

output "jenkins_public_ip" {
  value = module.jenkins.public_ip
}

output "app_public_ip" {
  value = module.app.public_ip
}

output "monitoring_public_ip" {
  value = module.monitoring.public_ip
}

output "private_ips" {
  value = {
    jenkins    = module.jenkins.private_ip
    app        = module.app.private_ip
    monitoring = module.monitoring.private_ip
  }
}

output "app_url" {
  value = "https://notes.${local.app_dash}.sslip.io"
}

output "jenkins_url" {
  value = "https://jenkins.${local.jenkins_dash}.sslip.io"
}

output "ssh_bastion" {
  description = "Log in to the Jenkins server (the bastion)"
  value       = "ssh ubuntu@${module.jenkins.public_ip}"
}

output "ssh_app" {
  description = "Log in to the app server through the bastion"
  value       = "ssh -J ubuntu@${module.jenkins.public_ip} ubuntu@${module.app.private_ip}"
}

output "ssh_monitoring" {
  description = "Log in to the monitoring server through the bastion"
  value       = "ssh -J ubuntu@${module.jenkins.public_ip} ubuntu@${module.monitoring.private_ip}"
}

output "rds_endpoint" {
  value = module.database.endpoint
}

output "ecr_repository_url" {
  value = data.aws_ecr_repository.app.repository_url
}

output "ssm_prefix" {
  value = local.ssm_prefix
}
