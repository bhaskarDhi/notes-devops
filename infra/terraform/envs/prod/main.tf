locals {
  name       = "${var.project}-${var.environment}"
  ssm_prefix = "/${var.project}/${var.environment}"
}

# ---------- lookups (nothing created) ----------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

data "aws_ecr_repository" "app" {
  name = "notes-app"
}

# ---------- SSH keys ----------

resource "aws_key_pair" "admin" {
  key_name   = "${local.name}-admin"
  public_key = file(pathexpand(var.public_key_path))
}

resource "tls_private_key" "deploy" {
  algorithm = "ED25519"
}

resource "aws_ssm_parameter" "deploy_ssh_private_key" {
  name  = "${local.ssm_prefix}/deploy_ssh_private_key"
  type  = "SecureString"
  value = tls_private_key.deploy.private_key_openssh
}

locals {
  deploy_key_cloud_init = <<-EOT
    #cloud-config
    ssh_authorized_keys:
      - ${trimspace(tls_private_key.deploy.public_key_openssh)}
  EOT
}

# ---------- deployed image tag (Jenkins updates it) ----------

resource "aws_ssm_parameter" "image_tag" {
  name  = "${local.ssm_prefix}/image_tag"
  type  = "String"
  value = "none"

  lifecycle {
    ignore_changes = [value]
  }
}

# ---------- Jenkins secrets (Ansible writes them into Jenkins) ----------

resource "random_password" "jenkins_admin" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "jenkins_admin_password" {
  name  = "${local.ssm_prefix}/jenkins_admin_password"
  type  = "SecureString"
  value = random_password.jenkins_admin.result
}

resource "random_password" "github_webhook_secret" {
  length  = 40
  special = false
}

resource "aws_ssm_parameter" "github_webhook_secret" {
  name  = "${local.ssm_prefix}/github_webhook_secret"
  type  = "SecureString"
  value = random_password.github_webhook_secret.result
}

# ---------- modules ----------

module "network" {
  source = "../../modules/network"

  name                 = local.name
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

module "security" {
  source = "../../modules/security"

  name       = local.name
  vpc_id     = module.network.vpc_id
  admin_cidr = var.admin_cidr
}

module "iam" {
  source = "../../modules/iam"

  name               = local.name
  ecr_repository_arn = data.aws_ecr_repository.app.arn
  ssm_prefix         = local.ssm_prefix
}

module "jenkins" {
  source = "../../modules/server"

  name               = "${local.name}-jenkins"
  role               = "jenkins"
  ami_id             = data.aws_ami.ubuntu.id
  instance_type      = var.jenkins_instance_type
  subnet_id          = module.network.public_subnet_ids[0]
  security_group_ids = [module.security.jenkins_sg_id]
  key_name           = aws_key_pair.admin.key_name
  instance_profile   = module.iam.jenkins_instance_profile
  root_volume_size   = 30
}

module "app" {
  source = "../../modules/server"

  name               = "${local.name}-app"
  role               = "app"
  ami_id             = data.aws_ami.ubuntu.id
  instance_type      = var.app_instance_type
  subnet_id          = module.network.public_subnet_ids[0]
  security_group_ids = [module.security.app_sg_id]
  key_name           = aws_key_pair.admin.key_name
  instance_profile   = module.iam.app_instance_profile
  user_data          = local.deploy_key_cloud_init
}

module "monitoring" {
  source = "../../modules/server"

  name               = "${local.name}-monitoring"
  role               = "monitoring"
  ami_id             = data.aws_ami.ubuntu.id
  instance_type      = var.monitoring_instance_type
  subnet_id          = module.network.public_subnet_ids[1]
  security_group_ids = [module.security.monitoring_sg_id]
  key_name           = aws_key_pair.admin.key_name
  instance_profile   = module.iam.monitoring_instance_profile
  user_data          = local.deploy_key_cloud_init
}

module "database" {
  source = "../../modules/database"

  name               = local.name
  private_subnet_ids = module.network.private_subnet_ids
  security_group_id  = module.security.rds_sg_id
  ssm_prefix         = local.ssm_prefix
}

module "alarms" {
  source = "../../modules/alarms"

  name          = local.name
  alert_email   = var.alert_email
  db_identifier = module.database.db_identifier
  instance_ids = {
    jenkins    = module.jenkins.instance_id
    app        = module.app.instance_id
    monitoring = module.monitoring.instance_id
  }
}
