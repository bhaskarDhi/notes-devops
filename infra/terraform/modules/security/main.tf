# ---------- security groups ----------

resource "aws_security_group" "jenkins" {
  name        = "${var.name}-jenkins-sg"
  description = "Jenkins + bastion"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-jenkins-sg" }
}

resource "aws_security_group" "app" {
  name        = "${var.name}-app-sg"
  description = "Notes app server"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-app-sg" }
}

resource "aws_security_group" "monitoring" {
  name        = "${var.name}-monitoring-sg"
  description = "Prometheus, Grafana, Loki, Alertmanager"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-monitoring-sg" }
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds-sg"
  description = "PostgreSQL (RDS)"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-rds-sg" }
}

# ---------- outgoing traffic: servers may reach the internet ----------

resource "aws_vpc_security_group_egress_rule" "all_out" {
  for_each = {
    jenkins    = aws_security_group.jenkins.id
    app        = aws_security_group.app.id
    monitoring = aws_security_group.monitoring.id
  }

  security_group_id = each.value
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outgoing traffic"
}

# ---------- Jenkins / bastion ----------

resource "aws_vpc_security_group_ingress_rule" "jenkins_ssh_admin" {
  security_group_id = aws_security_group.jenkins.id
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.admin_cidr
  description       = "SSH from admin IP only"
}

resource "aws_vpc_security_group_ingress_rule" "jenkins_web" {
  for_each = { http = 80, https = 443 }

  security_group_id = aws_security_group.jenkins.id
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Jenkins web (${each.key}), GitHub webhooks, LetsEncrypt"
}

resource "aws_vpc_security_group_ingress_rule" "jenkins_node_exporter" {
  security_group_id            = aws_security_group.jenkins.id
  ip_protocol                  = "tcp"
  from_port                    = 9100
  to_port                      = 9100
  referenced_security_group_id = aws_security_group.monitoring.id
  description                  = "Prometheus scrapes node_exporter"
}

# ---------- App ----------

resource "aws_vpc_security_group_ingress_rule" "app_web" {
  for_each = { http = 80, https = 443 }

  security_group_id = aws_security_group.app.id
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Website (${each.key})"
}

resource "aws_vpc_security_group_ingress_rule" "app_ssh_from_jenkins" {
  security_group_id            = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.jenkins.id
  description                  = "SSH from Jenkins/bastion (Ansible)"
}

resource "aws_vpc_security_group_ingress_rule" "app_metrics" {
  for_each = { node_exporter = 9100, cadvisor = 8081, app = 3000 }

  security_group_id            = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.monitoring.id
  description                  = "Prometheus scrapes ${each.key}"
}

# ---------- Monitoring ----------

resource "aws_vpc_security_group_ingress_rule" "monitoring_ssh_from_jenkins" {
  security_group_id            = aws_security_group.monitoring.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.jenkins.id
  description                  = "SSH from Jenkins/bastion (Ansible, tunnels)"
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_loki" {
  for_each = {
    app     = aws_security_group.app.id
    jenkins = aws_security_group.jenkins.id
  }

  security_group_id            = aws_security_group.monitoring.id
  ip_protocol                  = "tcp"
  from_port                    = 3100
  to_port                      = 3100
  referenced_security_group_id = each.value
  description                  = "Alloy on ${each.key} sends logs to Loki"
}

# ---------- RDS ----------

resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id            = aws_security_group.rds.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
  description                  = "PostgreSQL from the app server only"
}
