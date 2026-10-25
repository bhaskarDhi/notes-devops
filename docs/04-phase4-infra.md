# Phase 4: Terraform `prod` stack (VPC, servers, RDS, IAM, alarms)

**Goal:** build the whole AWS environment from code: network, firewalls, permissions, 3 servers, the database, secrets and alarms.

**Done when:** `terraform apply` creates all 70 resources, SSH reaches every server through the bastion, and RDS shows `available`.

---

## 4.1 What gets created

```text
VPC 10.20.0.0/16 (ap-south-1)
├── Internet gateway
├── Public subnets   10.20.1.0/24 (zone a)   10.20.2.0/24 (zone b)   → route 0.0.0.0/0 → internet gateway
│   ├── jenkins     t3.medium  30 GB  (bastion; public SSH from your IP only)
│   ├── app         t3.small   20 GB
│   └── monitoring  t3.small   20 GB  (zone b)
└── Private subnets  10.20.11.0/24 (zone a)  10.20.12.0/24 (zone b)  → no route outside the VPC
    └── RDS PostgreSQL 16  db.t4g.micro  20 GB

Outside the VPC: IAM roles, SSM parameters, SNS topic + email, CloudWatch alarms, key pair
```

| Module | Resources | Count |
|---|---|---|
| `network` | VPC, internet gateway, 4 subnets, 2 route tables, 4 associations | 12 |
| `security` | 4 security groups + 17 rules | 21 |
| `iam` | 3 roles, 3 inline policies, 3 SSM attachments, 3 instance profiles | 12 |
| `server` × 3 | one instance + one elastic IP per server | 6 |
| `database` | random password, subnet group, RDS instance, 5 SSM parameters | 8 |
| `alarms` | SNS topic + email subscription, 2 RDS alarms, 3 EC2 status alarms | 7 |
| root (`envs/prod`) | admin key pair, deploy key, 2 SSM parameters | 4 |
| **Total** | | **70** |

---

## 4.2 Decisions in this phase

| # | Decision | Why |
|---|---|---|
| P4-1 | One `server` module, used 3 times | every server gets the same settings (encrypted disk, IMDSv2, tags) with less code |
| P4-2 | A `Role` tag on every server (`app`, `jenkins`, `monitoring`) | Ansible (Phase 5) and Prometheus (Phase 8) find servers by tag instead of by IP |
| P4-3 | Private subnets in **2** zones | RDS needs a subnet group that covers at least 2 availability zones |
| P4-4 | Each security-group rule is a **separate resource** (`aws_vpc_security_group_ingress_rule`) | this is the current recommended style: one rule per resource, which makes plans easy to read |
| P4-5 | Rules point to **other security groups**, not IPs | a rule like "5432 from app-sg" keeps working when IPs change |
| P4-6 | IAM: one role per server, with **least privilege** | the app can only pull images. Jenkins can push images, read settings, record the deployed tag and list servers. Monitoring can read EC2 and CloudWatch. No server has access keys. |
| P4-7 | The app server gets **no** SSM permission | Ansible (run from Jenkins) writes the app's `.env`, so the app server never reads secrets itself |
| P4-8 | `AmazonSSMManagedInstanceCore` on all servers | gives an emergency shell through AWS Session Manager, even if SSH breaks |
| P4-9 | **IMDSv2** required (`http_tokens = "required"`) | protects the server's temporary AWS credentials from a common attack called SSRF |
| P4-10 | Encrypted gp3 disks | data is encrypted at rest; gp3 is cheaper and faster than gp2 |
| P4-11 | `ignore_changes = [ami]` | a new Ubuntu image must not quietly replace servers that are running |
| P4-12 | Elastic IPs | addresses stay the same for the whole session (sslip.io names, SSH) |
| P4-13 | Two SSH keys: **admin** (your Mac key) and **deploy** (Terraform generates it) | Jenkins/Ansible need a key to reach app and monitoring; your personal key never leaves your Mac |
| P4-14 | **cloud-init** installs the deploy public key on app and monitoring; the private key goes to SSM (SecureString) | nobody copies key files by hand; Ansible fetches the key from SSM |
| P4-15 | RDS: `db.t4g.micro`, single AZ, 1-day backups, no deletion protection, no final snapshot | the cheapest settings, for a learning environment that is destroyed after each session |
| P4-16 | DB password made by `random_password` and stored in SSM SecureString | nobody types or sees it; Ansible reads it at deploy time |
| P4-17 | Limited password characters (`override_special`) | RDS does not allow `/`, `@`, `"` or spaces in passwords |
| P4-18 | `image_tag` SSM parameter with `ignore_changes = [value]` | Jenkins updates it after each deploy, and Terraform must not reset it |
| P4-19 | CloudWatch alarms → SNS → email | AWS-level health alerts (RDS CPU/storage, EC2 status checks) that work even if our monitoring server is down |
| P4-20 | The ECR repository is **read** with a data source | it belongs to the bootstrap stack; `prod` only needs its ARN and URL |

---

## 4.3 Folder layout

```text
infra/terraform/
├── bootstrap/            (Phase 3)
├── modules/
│   ├── network/          variables.tf · main.tf · outputs.tf
│   ├── security/
│   ├── iam/
│   ├── server/
│   ├── database/         + versions.tf (uses the random provider)
│   └── alarms/
└── envs/
    └── prod/
        ├── versions.tf               providers + S3 backend (key prod/terraform.tfstate)
        ├── variables.tf
        ├── main.tf                   calls the modules
        ├── outputs.tf
        ├── terraform.tfvars.example  committed
        └── terraform.tfvars          your IP + email (NOT committed)
```

---

## 4.4 Root stack: `envs/prod`

<sub>File: `infra/terraform/envs/prod/versions.tf`</sub>

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket       = "notes-devops-tfstate-725072160791"
    key          = "prod/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      Stack       = "prod"
      ManagedBy   = "terraform"
    }
  }
}
```

<sub>File: `infra/terraform/envs/prod/variables.tf`</sub>

```hcl
variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "notes-devops"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.11.0/24", "10.20.12.0/24"]
}

variable "admin_cidr" {
  description = "Your public IP with /32 (curl -s https://checkip.amazonaws.com)"
  type        = string
}

variable "alert_email" {
  description = "Email for CloudWatch alarms"
  type        = string
}

variable "public_key_path" {
  description = "Your SSH public key on the Mac"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "jenkins_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "app_instance_type" {
  type    = string
  default = "t3.small"
}

variable "monitoring_instance_type" {
  type    = string
  default = "t3.small"
}
```

<sub>File: `infra/terraform/envs/prod/main.tf`</sub>

```hcl
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
```

| Part | Why |
|---|---|
| `local.name = "notes-devops-prod"` | one name prefix for everything |
| `local.ssm_prefix = "/notes-devops/prod"` | all settings for this environment sit under one path, so IAM can allow exactly that path |
| `data "aws_ami" "ubuntu"` | finds the newest official Ubuntu 24.04 image (owner `099720109477` = Canonical) |
| `aws_key_pair.admin` | your Mac's public key, so you can SSH (to the bastion directly, to the others through `-J`) |
| `tls_private_key.deploy` | a new key pair for Jenkins/Ansible |
| `local.deploy_key_cloud_init` | cloud-init text that says "add this public key to the ubuntu user" |
| jenkins has no `user_data` | only you (with the admin key) log in to the bastion |
| `module "..."` blocks | each one passes inputs to a module; outputs connect the modules (e.g. `module.security.app_sg_id`) |

<sub>File: `infra/terraform/envs/prod/outputs.tf`</sub>

```hcl
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
```

<sub>File: `infra/terraform/envs/prod/terraform.tfvars.example`</sub>

```
admin_cidr  = "YOUR.IP.ADDRESS/32"
alert_email = "you@example.com"
```

---

## 4.5 Module `network`

<sub>File: `infra/terraform/modules/network/main.tf`</sub>

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.name}-public-${count.index + 1}", Tier = "public" }
}

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "${var.name}-private-${count.index + 1}", Tier = "private" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
```

| Resource | Simple meaning |
|---|---|
| `aws_vpc` | your own private network; `enable_dns_hostnames` gives servers DNS names (RDS needs this) |
| `aws_internet_gateway` | the door between the VPC and the internet |
| `aws_subnet.public` (2) | where the servers live; `map_public_ip_on_launch` gives them public IPs |
| `aws_subnet.private` (2) | where RDS lives; no public IPs |
| `aws_route_table.public` | "send all traffic (`0.0.0.0/0`) to the internet gateway" |
| `aws_route_table.private` | no internet route at all, so RDS cannot be reached from outside |
| `aws_route_table_association` | connects each subnet to its route table |
| `count = length(...)` | makes one copy per CIDR in the list; `count.index` is 0, 1, … |

<sub>File: `infra/terraform/modules/network/variables.tf`</sub>

```hcl
variable "name" {
  description = "Name prefix for resources"
  type        = string
}

variable "vpc_cidr" {
  description = "IP range of the VPC"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "IP ranges of the public subnets (one per availability zone)"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "IP ranges of the private subnets (one per availability zone)"
  type        = list(string)
}
```

<sub>File: `infra/terraform/modules/network/outputs.tf`</sub>

```hcl
output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}
```

---

## 4.6 Module `security`

<sub>File: `infra/terraform/modules/security/main.tf`</sub>

```hcl
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
```

| Group | Port in | From |
|---|---|---|
| jenkins-sg | 22 | your IP (`admin_cidr`) |
| | 80, 443 | everyone (Jenkins web page, GitHub webhooks, Let's Encrypt) |
| | 9100 | monitoring-sg |
| app-sg | 80, 443 | everyone |
| | 22 | jenkins-sg |
| | 9100, 8081, 3000 | monitoring-sg |
| monitoring-sg | 22 | jenkins-sg |
| | 3100 | app-sg, jenkins-sg |
| rds-sg | 5432 | app-sg |
| all EC2 groups | outgoing: everything | (download packages and images) |

AWS gives every new group an "allow all outgoing" rule, but Terraform removes it, so we add the outgoing rules ourselves. RDS gets **no** outgoing rule because it never starts connections.

`for_each = { http = 80, https = 443 }` creates one rule per entry. `each.key` is the name (`http`) and `each.value` is the port (`80`).

<sub>File: `infra/terraform/modules/security/variables.tf`</sub>

```hcl
variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "admin_cidr" {
  description = "Your public IP with /32: the only address allowed to SSH to the bastion"
  type        = string
}
```

---

## 4.7 Module `iam`

<sub>File: `infra/terraform/modules/iam/main.tf`</sub>

```hcl
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  ssm_arn = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}"
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ================= APP server: pull image, read its settings =================

resource "aws_iam_role" "app" {
  name               = "${var.name}-app-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "app-permissions"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

# ================= JENKINS server: push images, read/write deploy settings, find servers =================

resource "aws_iam_role" "jenkins" {
  name               = "${var.name}-jenkins-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "jenkins" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = [var.ecr_repository_arn]
  }
  statement {
    sid       = "ReadSettings"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [local.ssm_arn, "${local.ssm_arn}/*"]
  }
  statement {
    sid       = "RecordDeployedTag"
    actions   = ["ssm:PutParameter"]
    resources = ["${local.ssm_arn}/image_tag"]
  }
  statement {
    sid       = "AnsibleDynamicInventory"
    actions   = ["ec2:DescribeInstances", "ec2:DescribeTags", "ec2:DescribeRegions"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "jenkins" {
  name   = "jenkins-permissions"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins.json
}

# ================= MONITORING server: find targets, read CloudWatch, read SMTP password =================

resource "aws_iam_role" "monitoring" {
  name               = "${var.name}-monitoring-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "monitoring" {
  statement {
    sid       = "PrometheusEc2Discovery"
    actions   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones"]
    resources = ["*"]
  }
  statement {
    sid = "GrafanaCloudWatch"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "cloudwatch:DescribeAlarms",
      "logs:DescribeLogGroups",
      "tag:GetResources",
      "rds:DescribeDBInstances",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "monitoring" {
  name   = "monitoring-permissions"
  role   = aws_iam_role.monitoring.id
  policy = data.aws_iam_policy_document.monitoring.json
}

# ================= all servers: AWS Systems Manager (emergency shell access, no open port) =================

resource "aws_iam_role_policy_attachment" "ssm_core" {
  for_each = {
    app        = aws_iam_role.app.name
    jenkins    = aws_iam_role.jenkins.name
    monitoring = aws_iam_role.monitoring.name
  }

  role       = each.value
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ================= instance profiles (how an EC2 server "wears" a role) =================

resource "aws_iam_instance_profile" "app" {
  name = "${var.name}-app-profile"
  role = aws_iam_role.app.name
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.name}-jenkins-profile"
  role = aws_iam_role.jenkins.name
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${var.name}-monitoring-profile"
  role = aws_iam_role.monitoring.name
}
```

| Term | Simple meaning |
|---|---|
| **role** | a set of permissions that a service can "wear" |
| **assume role policy** (`ec2_assume`) | who is allowed to wear the role; here, EC2 servers |
| **policy** | the list of allowed actions and the resources they apply to |
| **instance profile** | the holder that attaches a role to an EC2 server |
| **least privilege** | allow only what is needed (e.g. the app can pull from **this** ECR repo only) |

| Role | Allowed |
|---|---|
| app | ECR login + pull `notes-app` |
| jenkins | ECR login + push/pull `notes-app`; read `/notes-devops/prod/*`; write `/notes-devops/prod/image_tag`; list EC2 servers |
| monitoring | list EC2 servers (for Prometheus discovery); read CloudWatch/RDS metrics (for Grafana) |
| all | AWS Systems Manager (Session Manager) |

The server gets **temporary credentials** automatically from the instance metadata service. Nothing is stored on disk.

---

## 4.8 Module `server`

<sub>File: `infra/terraform/modules/server/main.tf`</sub>

```hcl
resource "aws_instance" "this" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  key_name               = var.key_name
  iam_instance_profile   = var.instance_profile
  user_data              = var.user_data

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = var.name
    Role = var.role
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip" "this" {
  instance = aws_instance.this.id
  domain   = "vpc"

  tags = { Name = "${var.name}-ip" }
}
```

<sub>File: `infra/terraform/modules/server/variables.tf`</sub>

```hcl
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
```

---

## 4.9 Module `database`

<sub>File: `infra/terraform/modules/database/main.tf`</sub>

```hcl
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
```

| Setting | Why |
|---|---|
| `engine_version = "16"` | PostgreSQL 16; AWS picks the newest 16.x, and `auto_minor_version_upgrade` keeps it patched |
| `publicly_accessible = false` + private subnets + rds-sg | three layers of protection: no public IP, no internet route, and only the app may connect |
| `storage_encrypted = true` | data is encrypted at rest |
| `backup_retention_period = 1` | an automatic daily backup, kept for 1 day |
| `deletion_protection = false`, `skip_final_snapshot = true` | lets `terraform destroy` remove it quickly (it only holds demo data) |
| SSM parameters | `db_host`, `db_port`, `db_name`, `db_user` (String) + `db_password` (SecureString), read by Ansible |

RDS for PostgreSQL 16 requires SSL by default. The app's `DB_SSL` setting (Phase 1) already handles this.

---

## 4.10 Module `alarms`

<sub>File: `infra/terraform/modules/alarms/main.tf`</sub>

```hcl
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------- RDS ----------

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name}-rds-cpu-high"
  alarm_description   = "RDS CPU above 80% for 10 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = var.db_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.name}-rds-storage-low"
  alarm_description   = "RDS free storage below 2 GB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = var.db_identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2147483648
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# ---------- EC2: AWS health checks of each server ----------

resource "aws_cloudwatch_metric_alarm" "ec2_status" {
  for_each = var.instance_ids

  alarm_name          = "${var.name}-${each.key}-status-check-failed"
  alarm_description   = "${each.key} server failed the AWS status check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
```

| Alarm | Fires when |
|---|---|
| `rds-cpu-high` | average RDS CPU stays above 80% for 2 × 5 minutes |
| `rds-storage-low` | free storage drops below 2 GB (2147483648 bytes) |
| `<server>-status-check-failed` | the AWS health check fails for 3 minutes |

`ok_actions` also send an email once the problem is gone. **You must click "Confirm subscription"** in the first AWS email, or no alarm emails will arrive.

---

## 4.11 Commands

```bash
cd ~/Documents/"nodejs cicd"
git checkout main && git pull
git checkout -b feature/phase-4-infra
cd infra/terraform/envs/prod

cat > terraform.tfvars <<EOF
admin_cidr  = "$(curl -s https://checkip.amazonaws.com)/32"
alert_email = "YOUR_EMAIL@gmail.com"
EOF

terraform init          # downloads aws, random, tls (the AWS provider is big: wait, don't press Ctrl+C)
terraform validate
terraform plan          # Plan: 70 to add, 0 to change, 0 to destroy
terraform apply         # about 10 minutes (RDS is slow)
terraform output

aws configure set region ap-south-1
ssh ubuntu@JENKINS_IP "hostname"
ssh -J ubuntu@JENKINS_IP ubuntu@APP_PRIVATE_IP "hostname"
ssh -J ubuntu@JENKINS_IP ubuntu@MONITORING_PRIVATE_IP "hostname"
aws ssm get-parameters-by-path --path /notes-devops/prod --query "Parameters[].Name"
aws rds describe-db-instances --db-instance-identifier notes-devops-prod-db --query "DBInstances[0].DBInstanceStatus"
```

| Command / part | Meaning |
|---|---|
| `cat > file <<EOF ... EOF` | writes the lines between the two `EOF` markers into a file |
| `$(curl -s https://checkip.amazonaws.com)` | asks AWS for your current public IP and puts the answer here |
| `/32` | means "exactly this one IP address" |
| `ssh -J BASTION TARGET` | **jump host**: SSH to the bastion first, then from there to the target's private IP. Your key is used for both hops, so the target never needs a public SSH port. |

GitHub:

```bash
cd ~/Documents/"nodejs cicd"
git add infra docs
git status --short
git commit -m "Phase 4: Terraform prod stack (VPC, EC2, RDS, IAM, alarms)"
git push -u origin feature/phase-4-infra
gh pr create --base main --head feature/phase-4-infra --fill
gh pr merge feature/phase-4-infra --merge --delete-branch
git checkout main
git pull
```

End of each session (saves money):

```bash
cd ~/Documents/"nodejs cicd"/infra/terraform/envs/prod
terraform destroy
```

The bootstrap stack (S3 state bucket + ECR) is **never** destroyed. It costs almost nothing.

---

## 4.12 Results

```text
app_public_ip        = "16.4.130.144"
app_url              = "https://notes.16-4-130-144.sslip.io"
ecr_repository_url   = "725072160791.dkr.ecr.ap-south-1.amazonaws.com/notes-app"
jenkins_public_ip    = "15.206.136.1"
jenkins_url          = "https://jenkins.15-206-136-1.sslip.io"
monitoring_public_ip = "13.233.35.234"
private_ips          = { app = "10.20.1.64", jenkins = "10.20.1.247", monitoring = "10.20.2.146" }
rds_endpoint         = "notes-devops-prod-db.cnoq2quewlv9.ap-south-1.rds.amazonaws.com"
ssh_app              = "ssh -J ubuntu@15.206.136.1 ubuntu@10.20.1.64"
ssh_bastion          = "ssh ubuntu@15.206.136.1"
ssh_monitoring       = "ssh -J ubuntu@15.206.136.1 ubuntu@10.20.2.146"
ssm_prefix           = "/notes-devops/prod"
```

| Check | Result |
|---|---|
| SSH to bastion / app / monitoring | `ip-10-20-1-247`, `ip-10-20-1-64`, `ip-10-20-2-146` |
| SSM parameters | 7 (db_host, db_name, db_password, db_port, db_user, deploy_ssh_private_key, image_tag) |
| RDS status | `available` |

(The IPs change after every destroy + apply.)

---

## 4.13 Problems and fixes

### `Provider installation was canceled by an interrupt signal`
- **Cause:** Ctrl+C was pressed while `terraform init` was downloading the AWS provider, which is several hundred MB.
- **Fix:** run `terraform init` again and wait for it to finish.

### `InvalidParameterValue: Invalid rule description`
- **Cause:** the rule description had an apostrophe (`Let's Encrypt`). AWS allows only `a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*` in descriptions.
- **Fix:** change it to `LetsEncrypt` and run `terraform apply` again. Terraform only created what was missing, because everything else was already in the state.
- **Lesson:** a failed apply is not a disaster. The state remembers what succeeded, so fix the problem and apply again.

### `NoRegion: You must specify a region`
- **Cause:** the AWS CLI had no default region. Terraform has its own region in the provider block, but the CLI does not use it.
- **Fix:** `aws configure set region ap-south-1`.
