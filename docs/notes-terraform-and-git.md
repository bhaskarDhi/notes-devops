# Notes: Terraform and Git/GitHub (from zero to this project)

**Project:** notes-devops · **Author:** Bhaskar Bora · **Date:** 25 October 2026

> Part A explains Terraform from the very basics up to everything used in this project (modules, remote state in S3, locking, two stacks). Part B explains Git and GitHub: every idea and every command we used, and why.

---

# Part A: Terraform

## A1. What Terraform is

**Terraform** is a tool that creates and changes cloud resources (servers, networks, databases...) from **text files**. This idea is called **Infrastructure as Code (IaC)**.

| Without Terraform (clicking in the AWS console) | With Terraform |
|---|---|
| Slow, many clicks | One command creates everything |
| Easy to forget a setting | Every setting is written in a file |
| Hard to repeat exactly (dev, prod, next session) | Same files → same result every time |
| No history of who changed what | Files are in Git: full history, reviews via Pull Requests |
| Hard to delete everything cleanly | `terraform destroy` removes all of it |

### Declarative, not step-by-step

You don't write *"create a VPC, then create a subnet..."*. You write **what should exist**:

```hcl
resource "aws_vpc" "this" {
  cidr_block = "10.20.0.0/16"
}
```

Terraform compares **what you wrote** with **what exists** and does only the difference. Run it twice: the second time it does nothing ("No changes"). This is called **idempotent**.

> **Analogy:** Terraform is like an architect's drawing. You change the drawing; the builder (Terraform) works out which walls to add or remove.

---

## A2. How Terraform works

```text
  your .tf files ──┐
                   ├──► terraform plan ──► "what will change" ──► terraform apply ──► AWS
  state (memory) ──┘                                                   │
        ▲                                                              │
        └──────────────── Terraform updates the state ◄────────────────┘
```

| Part | What it is |
|---|---|
| **Configuration** | your `.tf` files (what you want) |
| **Provider** | a plugin that knows how to talk to one platform (AWS, random, tls...) |
| **State** | Terraform's memory: which real resources belong to which block, their IDs and attributes |
| **Plan** | the difference between configuration and reality, shown before anything happens |
| **Apply** | carry out the plan |

---

## A3. The language (HCL) basics

Terraform files use **HCL** (HashiCorp Configuration Language). A file is a list of **blocks**:

```hcl
BLOCK_TYPE "LABEL_1" "LABEL_2" {
  argument = value
}
```

### The block types we use

| Block | Purpose | Example in our project |
|---|---|---|
| `terraform` | Terraform settings: version, providers, backend | `versions.tf` |
| `provider` | configure a provider (region, default tags) | `provider "aws" { region = var.region }` |
| `resource` | **create** something | `resource "aws_instance" "this" {...}` |
| `data` | **read** something that already exists (creates nothing) | `data "aws_ami" "ubuntu"`, `data "aws_ecr_repository" "app"` |
| `variable` | an input you can change | `variable "admin_cidr"` |
| `output` | a value printed after apply (and readable by others) | `output "app_url"` |
| `locals` | named values used inside the files | `local.name = "notes-devops-prod"` |
| `module` | use a folder of Terraform code as a building block | `module "network" { source = "../../modules/network" }` |

### Referring to other things

| Syntax | Means | Example |
|---|---|---|
| `TYPE.NAME.ATTRIBUTE` | an attribute of a resource | `aws_vpc.this.id` |
| `data.TYPE.NAME.ATTRIBUTE` | an attribute of a data source | `data.aws_ami.ubuntu.id` |
| `var.NAME` | a variable | `var.region` |
| `local.NAME` | a local value | `local.ssm_prefix` |
| `module.NAME.OUTPUT` | an output of a module | `module.network.vpc_id` |
| `"${...}"` | put a value inside a string | `"${var.project}-${var.environment}"` |

**Dependencies are automatic:** because the subnet uses `aws_vpc.this.id`, Terraform knows it must create the VPC **first**. (`depends_on` exists for rare cases where there is no reference.)

### Types

| Type | Example |
|---|---|
| `string` | `"ap-south-1"` |
| `number` | `20` |
| `bool` | `true` |
| `list(string)` | `["10.20.1.0/24", "10.20.2.0/24"]` |
| `map(string)` | `{ app = "i-123", jenkins = "i-456" }` |

### Making many copies: `count` and `for_each`

```hcl
resource "aws_subnet" "public" {
  count      = length(var.public_subnet_cidrs)          # 2 copies
  cidr_block = var.public_subnet_cidrs[count.index]     # 0, then 1
}
```

```hcl
resource "aws_vpc_security_group_ingress_rule" "app_web" {
  for_each  = { http = 80, https = 443 }                # one copy per key
  from_port = each.value                                # 80, then 443
  description = "Website (${each.key})"                 # "http", then "https"
}
```

| | `count` | `for_each` |
|---|---|---|
| Copies are named | `[0]`, `[1]` | `["http"]`, `["https"]` |
| Use when | identical copies, a list | each copy has a meaning (a map) |
| Removing one item | can shift and recreate later items | only that item changes |

`aws_subnet.public[*].id` (the **splat** `[*]`) means "the id of every copy" → a list.

### Functions we use

| Function | What it does | Where |
|---|---|---|
| `file(path)` | read a file's text | public SSH key |
| `pathexpand("~/.ssh/...")` | turn `~` into your home folder | public key path |
| `length(list)` | number of items | subnet count |
| `replace(s, ".", "-")` | replace text | IP → `13-205-81-47` for sslip.io |
| `trimspace(s)` | remove spaces/newlines at the ends | deploy public key |
| `tostring(x)` | number → text | RDS port in SSM |
| `jsonencode(obj)` | HCL object → JSON text | ECR lifecycle policy |

### `lifecycle` rules

| Rule | Meaning | Where |
|---|---|---|
| `prevent_destroy = true` | Terraform refuses to delete it | state bucket |
| `ignore_changes = [value]` | don't undo changes made outside Terraform | SSM `image_tag` (Jenkins changes it) |
| `ignore_changes = [ami]` | don't replace servers when Ubuntu publishes a newer image | `server` module |

---

## A4. Providers and versions

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}
```

| Item | Meaning |
|---|---|
| `required_version = ">= 1.10"` | Terraform itself must be at least 1.10 (needed for the S3 lock file) |
| `source = "hashicorp/aws"` | which plugin, from the Terraform Registry |
| `version = "~> 6.0"` | any 6.x version (6.0, 6.70...), never 7.0 (a major version may break things) |
| `.terraform/` folder | where `init` downloads plugins (big, never committed) |
| `.terraform.lock.hcl` | records the **exact** plugin version chosen (e.g. 6.70.0) and its checksums. **Committed**, so everyone and every machine uses the same version |

Providers in this project: **aws** (everything in AWS), **random** (database password), **tls** (deploy SSH key).

---

## A5. Variables, tfvars and outputs

```hcl
variable "admin_cidr" {
  description = "Your public IP with /32"
  type        = string
}
```

Ways to give a value (later ones win):

1. `default` in the variable block
2. `terraform.tfvars` file (loaded automatically)
3. `-var 'admin_cidr=1.2.3.4/32'` on the command line

**Our pattern:** `terraform.tfvars.example` (committed, fake values) + `terraform.tfvars` (your real values, **not** committed: it contains your IP and email).

**Outputs** print useful results (`app_url`, `ssh_app`...) and are shown again with `terraform output`.

---

## A6. State: Terraform's memory

The **state** file (`terraform.tfstate`) is JSON that maps each block to a real resource:

```text
module.app.aws_instance.this  ⇄  i-0abc123...  (private IP 10.20.1.15, ...)
```

| Why state matters | |
|---|---|
| Without it | Terraform would not know `i-0abc123` is "the app server" and would try to create a second one |
| It contains secrets | e.g. the RDS password and the deploy private key, in plain text |
| Never | edit it by hand, delete it, or commit it to Git |

### Local state vs remote state

| Local state (beginner project) | Remote state in S3 (this project) |
|---|---|
| file on your Mac | object in an S3 bucket |
| Mac lost or broken → Terraform forgets everything | stored by AWS, extremely durable |
| no history | **versioning**: every old state can be restored |
| secrets sit unprotected on the laptop | **encrypted** at rest, access controlled by IAM |
| two people/jobs can't share it | Mac, Jenkins and teammates use the same state |
| nothing stops two `apply` runs at once | **locking**: the second run waits/fails |

### Why S3 (and not something else)?

- We already use AWS; S3 needs no extra account or service.
- Very cheap (a state file is a few KB).
- Supports versioning, encryption, blocking public access, IAM permissions.
- Terraform's S3 backend supports **native locking** with a small lock file (`use_lockfile = true`). The older DynamoDB lock table is deprecated, so we don't need it.

### The backend block

```hcl
terraform {
  backend "s3" {
    bucket       = "notes-devops-tfstate-725072160791"
    key          = "prod/terraform.tfstate"     # path inside the bucket
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

- The backend block **cannot use variables** (Terraform reads it before anything else), so the bucket name is written directly.
- Each stack has its own `key`: `bootstrap/terraform.tfstate`, `prod/terraform.tfstate`.
- While a command runs, Terraform creates `prod/terraform.tfstate.tflock`. If a run crashes and the lock stays, `terraform force-unlock LOCK_ID` removes it (only when you are sure nothing is running).

### Chicken and egg (why "bootstrap")

The bucket must exist **before** any stack can store state in it. So:

1. The `bootstrap` stack creates the bucket using **local** state.
2. We add the backend block and run `terraform init -migrate-state`: Terraform **copies** the local state into the bucket.
3. The local file is deleted. Now even the bootstrap stack's state is in S3.

---

## A7. Modules

A **module** is a folder of `.tf` files with inputs (variables) and outputs. You use it like a function.

```text
modules/server/
├── variables.tf   inputs:  name, role, instance_type, subnet_id, ...
├── main.tf        creates: aws_instance + aws_eip
└── outputs.tf     results: instance_id, public_ip, private_ip
```

```hcl
module "app" {
  source        = "../../modules/server"
  name          = "notes-devops-prod-app"
  role          = "app"
  instance_type = "t3.small"
  ...
}
```

| Why modules | |
|---|---|
| Reuse | one `server` module → 3 servers (app, jenkins, monitoring) |
| Small, readable parts | network, security, iam, database, alarms are separate |
| Clear connections | outputs of one module are inputs of another (`module.network.vpc_id` → `module.security`) |
| Easy to add environments later | a `staging` stack can call the same modules with other values |

**Our modules:** `network`, `security`, `iam`, `server`, `database`, `alarms`. The **root module** `envs/prod` calls them.

---

## A8. Two stacks: `bootstrap` and `prod`

| Stack | Contains | State key | Lifetime |
|---|---|---|---|
| `bootstrap` | S3 state bucket, ECR repository | `bootstrap/terraform.tfstate` | kept |
| `prod` | VPC, subnets, security groups, IAM, 3 servers, RDS, SSM, alarms (70 resources) | `prod/terraform.tfstate` | destroyed after each session |

Why separate? **Blast radius**: `terraform destroy` in `prod` can never touch the bucket or the images. And things that change rarely (bootstrap) are kept apart from things that change often (prod).

---

## A9. Commands

| Command | What it does | When |
|---|---|---|
| `terraform init` | download providers and modules, connect the backend | first time, after adding providers/modules/backend |
| `terraform init -migrate-state` | move state to a new backend | bootstrap step 2 |
| `terraform init -upgrade` | allow newer provider versions (within the constraint) | when you want updates |
| `terraform fmt` | format files neatly (`-check` only reports) | before committing; CI uses `-check` |
| `terraform validate` | check syntax and references | before plan; CI |
| `terraform plan` | show what would change | always before apply |
| `terraform apply` | make the changes (asks "yes") | |
| `terraform output` | show outputs | anytime |
| `terraform destroy` | delete everything in this stack | end of a practice session (`prod` only) |
| `terraform state list` | list resources in the state | inspecting |
| `terraform state show ADDRESS` | details of one resource | inspecting |
| `terraform force-unlock ID` | remove a stuck lock | only after a crash |

### Reading a plan

| Symbol | Meaning |
|---|---|
| `+` | create |
| `~` | change in place |
| `-` | destroy |
| `-/+` | destroy and recreate (replace) |
| `<=` | read a data source |
| `(known after apply)` | AWS decides the value when creating it |

**Always read the last line** (`Plan: 70 to add, 0 to change, 0 to destroy.`) before typing `yes`.

---

## A10. Every resource type in this project

| Resource / data source | What it is |
|---|---|
| `aws_s3_bucket` + `_versioning`, `_server_side_encryption_configuration`, `_public_access_block`, `_lifecycle_configuration` | the state bucket and its settings (each setting is its own resource in AWS provider v6) |
| `aws_ecr_repository`, `aws_ecr_lifecycle_policy` | image repository and cleanup rules |
| `aws_vpc` | your private network (10.20.0.0/16) |
| `aws_internet_gateway` | the VPC's door to the internet |
| `aws_subnet` | a slice of the VPC in one availability zone (public or private) |
| `aws_route_table` + `_association` | where traffic goes; public: `0.0.0.0/0 → internet gateway`; private: nowhere outside |
| `aws_security_group` | a firewall attached to servers/RDS |
| `aws_vpc_security_group_ingress_rule` / `_egress_rule` | one allowed incoming / outgoing rule (newer, recommended style: one resource per rule) |
| `aws_iam_role` | an identity that a service (EC2) can take on |
| `aws_iam_policy_document` (data) | builds a permission policy in HCL instead of raw JSON |
| `aws_iam_role_policy` | permissions written for one role (least privilege) |
| `aws_iam_role_policy_attachment` | attach an AWS-managed policy (e.g. SSM access) |
| `aws_iam_instance_profile` | the "container" that lets an EC2 server use a role |
| `aws_key_pair` | your public SSH key in AWS |
| `tls_private_key` | Terraform generates the deploy SSH key pair |
| `random_password` | Terraform generates the database password |
| `aws_ssm_parameter` | a setting or secret in Parameter Store (`String` or encrypted `SecureString`) |
| `aws_instance` | an EC2 server |
| `aws_eip` | a fixed public IP |
| `aws_db_subnet_group` | which private subnets RDS may use (needs 2 zones) |
| `aws_db_instance` | the RDS PostgreSQL database |
| `aws_sns_topic` + `_subscription` | a message channel + your email on it |
| `aws_cloudwatch_metric_alarm` | "if metric X crosses Y, send to SNS" |
| `aws_caller_identity` (data) | your account id |
| `aws_region` (data) | current region |
| `aws_availability_zones` (data) | zone names (ap-south-1a, 1b...) |
| `aws_ami` (data) | newest Ubuntu 24.04 image id |
| `aws_ecr_repository` (data) | the repo created by bootstrap (read by prod) |

### `default_tags`

```hcl
provider "aws" {
  default_tags {
    tags = { Project = "notes-devops", Stack = "prod", ManagedBy = "terraform" }
  }
}
```

Every AWS resource gets these tags automatically. In the console you can filter by `Project = notes-devops`, and Ansible/Prometheus find servers by the `Role` tag.

---

## A11. Good habits and common problems

- `plan` before `apply`; read the last line.
- `prod`: `terraform destroy` after each session (costs per hour). `bootstrap`: never.
- Never commit `terraform.tfstate`, `terraform.tfvars`, `.terraform/`. Do commit `.terraform.lock.hcl`.
- Don't change AWS resources by hand that Terraform manages: the next `plan` will try to undo it ("drift").

| Problem | Cause | Fix |
|---|---|---|
| `Provider installation was canceled by an interrupt signal` | Ctrl+C during `init` (the AWS provider is big) | run `terraform init` again and wait |
| `Error acquiring the state lock` | another run is active, or a crashed run left a lock | wait; if sure nothing runs: `terraform force-unlock ID` |
| SSH to the bastion stops working | your home IP changed | update `admin_cidr` in `terraform.tfvars`, `terraform apply` |
| `Plan: ... to destroy` you didn't expect | a change forces replacement (`-/+`) | stop, read why (`# forces replacement`), don't type yes |

---

# Part B: Git and GitHub

## B1. Git vs GitHub

| Git | GitHub |
|---|---|
| a program on your Mac that records versions of files | a website that stores Git repositories online |
| works offline | shares code with others and with Jenkins |
| commits, branches, history | Pull Requests, reviews, rules (protect `main`), webhooks |

## B2. The four places your code lives

```text
 working folder ──git add──► staging area ──git commit──► local repository ──git push──► GitHub (origin)
 (files you edit)            (chosen changes)              (history on your Mac)  ◄──git pull──
```

| Word | Meaning |
|---|---|
| **repository (repo)** | a project folder tracked by Git (the hidden `.git` folder holds the history) |
| **commit** | a saved snapshot with a message and an id (e.g. `4b97e45`) |
| **staging area** | the list of changes that go into the next commit |
| **branch** | a separate line of commits (`main`, `feature/...`) |
| **HEAD** | "where you are now" (current branch / commit) |
| **remote / origin** | the copy on GitHub; `origin` is its nickname |
| **push / pull** | upload your commits / download and merge GitHub's commits |
| **fetch** | download information from GitHub without changing your files |
| **merge** | combine one branch into another |
| **fast-forward** | the simple merge: your branch just moves forward, no merge commit needed |
| **merge commit** | a commit that joins two branches (`Merge pull request #1 ...`) |
| **Pull Request (PR)** | a request on GitHub to merge a branch into `main`; shows the changes, runs checks |
| **ruleset / branch protection** | GitHub rules for a branch, e.g. "only via PR", "no force push" |

## B3. Why branches and Pull Requests?

- `main` = what gets deployed. It must always work.
- New work happens on a **branch** (`feature/phase-4-infra`), so `main` is untouched until the work is ready.
- A **PR** shows exactly what changes, and later Jenkins tests it (✅/❌) **before** merging.
- The **ruleset** on `main` makes this mandatory: direct pushes are refused.

```text
main ───●───────────────●───────────── (always deployable)
         \             /
feature   ●───●───●───●     ← work here, then PR + merge
```

## B4. Every command we used

### Starting a repo

| Command | Why |
|---|---|
| `git init -b main` | turn the folder into a Git repo; first branch called `main` |
| `git remote add origin https://github.com/bhaskarDhi/notes-devops.git` | connect it to the GitHub repo |
| `git push -u origin main` | upload `main`; `-u` remembers the link so later `git push`/`git pull` need no names |

### Saving work

| Command | Why |
|---|---|
| `git status` / `git status --short` | what changed? (`??` new file, `M` modified, `A` added). **Check for secrets before committing** |
| `git add FILE_OR_FOLDER` / `git add .` | put changes into the staging area (`.gitignore` files are skipped) |
| `git commit -m "message"` | save a snapshot of the staged changes |
| `git commit --allow-empty -m "..."` | a commit with no changes (we used it to test the protection) |
| `git log --oneline -3` | the last 3 commits, one line each |

### Branches

| Command | Why |
|---|---|
| `git checkout -b feature/name` | create a new branch and switch to it |
| `git checkout main` | switch to `main` |
| `git branch` | list local branches (`*` = current) |
| `git branch -d name` | delete a local branch that is merged |
| `git push -u origin feature/name` | upload the branch to GitHub |

### Syncing with GitHub

| Command | Why |
|---|---|
| `git pull` | download new commits from GitHub and merge them into your branch |
| `git fetch --prune` | update information from GitHub and remove references to branches deleted there |
| `git reset --hard origin/main` | throw away local commits/changes; make your branch exactly like GitHub's |
| `git reset --hard HEAD~1` | throw away the last local commit (`HEAD~1` = one before the current) |

### Pull Requests with the GitHub CLI (`gh`)

| Command | Why |
|---|---|
| `brew install gh` | install the GitHub CLI |
| `gh auth login` | log in once (GitHub.com → HTTPS → Yes → browser) |
| `gh pr create --base main --head feature/name --fill` | open a PR from the branch into `main`; `--fill` uses the commit message as title |
| `gh pr merge feature/name --merge --delete-branch` | merge the PR (merge commit), delete the branch on GitHub and locally |

### From the beginner project

| Command | Why |
|---|---|
| `git rm --cached FILE` | stop tracking a file but keep it on disk (used to remove `.env`/`vendor` from Git) |
| `git remote set-url origin URL` | change the GitHub address (repo was renamed) |
| `git branch -m master main` | rename a branch |
| `git merge devops` | merge branch `devops` into the current branch |

## B5. The everyday flow (copy-paste)

```bash
cd ~/Documents/"nodejs cicd"
git checkout main
git pull                                   # start from the latest main
git checkout -b feature/short-name         # new branch

# ... edit files ...

git status --short                         # check: no secrets
git add .
git commit -m "Describe the change"
git push -u origin feature/short-name

gh pr create --base main --head feature/short-name --fill
# (Phase 6+: wait for the Jenkins ✅ on the PR)
gh pr merge feature/short-name --merge --delete-branch

git checkout main
git pull
```

**Branch names:** `feature/...` new work, `fix/...` bug fix, `docs/...` documentation.
**Commit messages:** short, present tense, says *what* and *why*: `Add RDS alarms`, `Fix SSL setting for RDS`.

## B6. `.gitignore`: what never goes to GitHub

```gitignore
node_modules/        # rebuilt with npm ci
.env                 # secrets
.env.*
!.env.example        # ...but the template is committed
*.pem                # keys
.terraform/          # downloaded providers
*.tfstate            # Terraform state (secrets)
*.tfstate.*
*.tfvars             # your IP, email
!*.tfvars.example
.DS_Store            # Mac junk
```

A file that is **already committed** stays tracked even if added to `.gitignore` later: remove it from Git with `git rm --cached FILE`.

## B7. Messages we saw and what they mean

| Message | Meaning | What to do |
|---|---|---|
| `Already up to date.` | nothing new on GitHub | nothing (if you expected changes: is the PR merged?) |
| `Fast-forward` | your branch simply moved forward to GitHub's commits | normal |
| `! [rejected] main -> main (non-fast-forward)` | GitHub has commits you don't have | `git pull` first |
| `GH013: Repository rule violations ... Changes must be made through a pull request` | the ruleset blocked a direct push to `main` | use a branch + PR (this is the protection working) |
| `deleting branch ... not yet merged to HEAD` | you deleted a local branch before its PR was merged | the commits are still on GitHub; merge the PR, then `git pull` |
| `branch 'X' set up to track 'origin/X'` | `-u` linked your branch to GitHub's | normal |

## B8. Why GitHub CLI instead of the website?

Both do the same. The CLI keeps everything in the terminal (no hunting for buttons) and the same commands can later be used in scripts. The website is still useful to **look at** PRs, changes and Jenkins results.
