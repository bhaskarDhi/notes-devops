# Phase 3: Terraform bootstrap (S3 state bucket + ECR)

**Goal:** a place where Terraform keeps its state safely (S3), and a place for the app images (ECR). Both stay between practice sessions.

**Done when:** the bootstrap state itself lives in S3 and `terraform plan` says `No changes`.

---

## 3.1 Why a separate bootstrap stack?

| Problem | Solution |
|---|---|
| Beginner project: `terraform.tfstate` only on the Mac. Lost Mac = Terraform forgets what it created. | State in an **S3 bucket**: versioned, encrypted, private |
| Two `apply` runs at the same time can corrupt the state | **Lock file** in S3 (`use_lockfile = true`) |
| Terraform cannot store state in a bucket that does not exist yet (chicken and egg) | Small **bootstrap** stack: create the bucket with local state, then **move** its own state into the bucket |
| Images must survive when servers are destroyed after each session | **ECR** repository lives in the bootstrap stack (never destroyed) |

### Two stacks

| Stack | Folder | Contains | Lifetime |
|---|---|---|---|
| `bootstrap` | `infra/terraform/bootstrap` | S3 state bucket, ECR repository | **kept** (cents per month) |
| `prod` | `infra/terraform/envs/prod` (Phase 4) | VPC, servers, RDS, IAM, alarms... | **destroyed after each session** |

---

## 3.2 Decisions

| # | Decision | Why |
|---|---|---|
| P3-1 | Bucket name `notes-devops-tfstate-<account id>` | S3 names are unique worldwide; the account id makes it unique and readable |
| P3-2 | `prevent_destroy = true` on the bucket | Terraform refuses to delete it, even by mistake |
| P3-3 | Versioning on | every old state version can be restored |
| P3-4 | Encryption `AES256` | the state contains secrets later (RDS password) |
| P3-5 | Block all public access | the bucket can never become public |
| P3-6 | Delete old state versions after 90 days | storage does not grow forever |
| P3-7 | Native S3 lock file, no DynamoDB table | DynamoDB locking is deprecated in the S3 backend; one less resource |
| P3-8 | ECR tags **IMMUTABLE** | a tag (git commit) can never be overwritten: `abc1234` always means the same image |
| P3-9 | ECR scan on push | free second vulnerability check next to Trivy (Phase 7) |
| P3-10 | ECR lifecycle: untagged after 1 day, keep newest 15 | storage stays small; still enough versions to roll back |
| P3-11 | `default_tags` on the provider | every resource carries `Project`, `Stack`, `ManagedBy` → easy to find and filter in AWS |

---

## 3.3 The files

<sub>File: `infra/terraform/bootstrap/versions.tf`</sub>

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      Stack     = "bootstrap"
      ManagedBy = "terraform"
    }
  }
}
```

<sub>File: `infra/terraform/bootstrap/variables.tf`</sub>

```hcl
variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used in resource names and tags"
  type        = string
  default     = "notes-devops"
}

variable "ecr_keep_images" {
  description = "How many tagged images to keep in ECR"
  type        = number
  default     = 15
}
```

<sub>File: `infra/terraform/bootstrap/main.tf`</sub>

```hcl
data "aws_caller_identity" "current" {}

locals {
  state_bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

# ---------- S3 bucket for Terraform state ----------

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# ---------- ECR repository for the app image ----------

resource "aws_ecr_repository" "app" {
  name                 = "notes-app"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Delete untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the newest tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_keep_images
        }
        action = { type = "expire" }
      }
    ]
  })
}
```

| Resource | What it is |
|---|---|
| `data.aws_caller_identity.current` | reads your account id (no resource created) |
| `aws_s3_bucket.tfstate` | the bucket |
| `aws_s3_bucket_versioning` | keep old versions |
| `aws_s3_bucket_server_side_encryption_configuration` | encrypt every object |
| `aws_s3_bucket_public_access_block` | never public |
| `aws_s3_bucket_lifecycle_configuration` | delete old versions after 90 days |
| `aws_ecr_repository.app` | image repository `notes-app` |
| `aws_ecr_lifecycle_policy.app` | image cleanup rules |

In AWS provider v6, each bucket setting is its **own resource** (versioning, encryption, ...). That is why one bucket = 5 resources. Total: **7 resources**.

<sub>File: `infra/terraform/bootstrap/outputs.tf`</sub>

```hcl
output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "region" {
  value = var.region
}

output "state_bucket" {
  description = "S3 bucket that stores Terraform state"
  value       = aws_s3_bucket.tfstate.bucket
}

output "ecr_repository_url" {
  description = "Where Jenkins pushes and the app server pulls images"
  value       = aws_ecr_repository.app.repository_url
}
```

<sub>File: `infra/terraform/bootstrap/backend.tf`</sub>

```hcl
terraform {
  backend "s3" {
    bucket       = "notes-devops-tfstate-725072160791"
    key          = "bootstrap/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

| Setting | Meaning |
|---|---|
| `bucket` | where the state is stored |
| `key` | file path inside the bucket (`bootstrap/terraform.tfstate`; Phase 4 uses `prod/terraform.tfstate`) |
| `encrypt` | encrypt the state object |
| `use_lockfile` | create `terraform.tfstate.tflock` next to the state while a command runs; a second run waits/fails instead of corrupting the state |

---

## 3.4 Commands

```bash
aws sts get-caller-identity          # must end with :user/terraform-cli

cd ~/Documents/"nodejs cicd"/infra/terraform/bootstrap

# step 1: create bucket + ECR (state is still local)
terraform init
terraform validate
terraform plan                       # Plan: 7 to add
terraform apply                      # yes

# step 2: move this stack's state into the bucket (backend.tf added)
terraform init -migrate-state        # "copy existing state to the new backend?" → yes
aws s3 ls s3://notes-devops-tfstate-725072160791/bootstrap/
terraform plan                       # No changes
rm terraform.tfstate terraform.tfstate.backup
```

GitHub:

```bash
cd ~/Documents/"nodejs cicd"
git checkout -b feature/phase-3-bootstrap
git add infra
git status --short
git commit -m "Phase 3: Terraform bootstrap (S3 state + ECR)"
git push -u origin feature/phase-3-bootstrap
gh pr create --base main --head feature/phase-3-bootstrap --fill
gh pr merge feature/phase-3-bootstrap --merge --delete-branch
git checkout main
git pull
```

GitHub CLI setup (once):

```bash
brew install gh
gh auth login                        # GitHub.com → HTTPS → Yes → Login with a web browser
```

---

## 3.5 Results

```text
Apply complete! Resources: 7 added, 0 changed, 0 destroyed.

aws_account_id     = "725072160791"
ecr_repository_url = "725072160791.dkr.ecr.ap-south-1.amazonaws.com/notes-app"
region             = "ap-south-1"
state_bucket       = "notes-devops-tfstate-725072160791"
```

Pull request #2 merged with `gh`.

---

## 3.6 Notes

- **Never delete** `bootstrap/terraform.tfstate` from the bucket, and never `terraform destroy` the bootstrap stack while images are needed.
- `.terraform.lock.hcl` **is** committed (same provider version for everyone). `.terraform/` and `*.tfstate` are not (`.gitignore`).
- Expected count in the plan was first written as 8; the real count is 7 (5 bucket resources + 2 ECR).
