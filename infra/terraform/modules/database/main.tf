resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "-_=+()!#%^*"
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db-subnets"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "${var.name}-db-subnets" }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-db"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  apply_immediately          = true
  deletion_protection        = false
  skip_final_snapshot        = true

  tags = { Name = "${var.name}-db" }
}

# ---------- connection settings for Ansible / the app ----------

resource "aws_ssm_parameter" "db" {
  for_each = {
    db_host = aws_db_instance.this.address
    db_port = tostring(aws_db_instance.this.port)
    db_name = var.db_name
    db_user = var.db_username
  }

  name  = "${var.ssm_prefix}/${each.key}"
  type  = "String"
  value = each.value
}

resource "aws_ssm_parameter" "db_password" {
  name  = "${var.ssm_prefix}/db_password"
  type  = "SecureString"
  value = random_password.db.result
}
