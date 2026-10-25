# Intermediate CI/CD: System Design

**Project:** Notes App (Node.js + PostgreSQL)  
**Author:** Bhaskar Bora  
**Level:** Intermediate (builds on the beginner Task App project)  
**Status:** Design, waiting for approval  
**Date:** 25 October 2026

> This document explains **what** we will build, **how the pieces connect**, and **why** each choice was made (with the alternatives we did not choose). Every later step refers back to these decisions.

---

## 1. What changes from the beginner level

| Area | Beginner (Task App) | Intermediate (Notes App) | Why the change |
|---|---|---|---|
| App | Laravel + PHP | **Node.js 24 (Express)** | learn a second stack; same CI/CD ideas |
| Database | PostgreSQL container on the server | **Amazon RDS** (managed PostgreSQL) | backups, updates and storage handled by AWS |
| Network | default VPC, one server | **own VPC** with public + private subnets | the database is not reachable from the internet |
| Servers | 1 EC2 | **3 EC2**: app, Jenkins, monitoring | each job on its own machine |
| Server setup | `user-data.sh` + manual `scp`/`ssh` | **Ansible** roles and playbooks | repeatable setup and deploys, no manual steps |
| Terraform | one folder, state on the Mac | **modules** + **remote state in S3** | reusable code; state safe and shared |
| Image registry | Docker Hub (password in Jenkins) | **Amazon ECR** (access via IAM role) | no registry password anywhere |
| Secrets | `.env.production` copied by hand | **AWS SSM Parameter Store** | secrets stored encrypted in AWS, read at deploy time |
| Jenkins | Docker on the Mac, polls every 2 min | **on AWS**, **GitHub webhook**, configured **as code** | instant builds; no home-IP problem |
| Git flow | push to `main` | **feature branch → Pull Request → CI → merge** | broken code cannot reach `main` |
| Pipeline | test → build → push → deploy | + **lint, real DB tests, image scan, smoke test, auto-rollback, email** | safer releases |
| HTTPS | none (http only) | **HTTPS** with Caddy + Let's Encrypt | encrypted traffic, also for webhooks |
| Monitoring | Node Exporter + Prometheus + Grafana | + **app metrics, container metrics, logs (Loki), uptime probe, alerts by email**, RDS alarms | know about problems before users do |
| Admin access | SSH from home IP to every server | **one bastion** (Jenkins host); others have no public SSH | fewer open doors |

---

## 2. Architecture

```text
                                   ┌──────────────── GitHub ────────────────┐
  Your Mac                         │  repo: notes-devops                     │
  ─────────                        │  feature/* ──Pull Request──► main       │
  • write code ── git push ──────► │  webhook (on push / PR) ───────┐        │
  • Terraform (infra)              └────────────────────────────────┼────────┘
  • Ansible (first setup)                                           │ HTTPS
  • Browser: app, Jenkins,                                          ▼
    Grafana (SSH tunnel)      ┌─────────────────────── AWS · ap-south-1 (Mumbai) · VPC 10.20.0.0/16 ──────────────────┐
                              │                                                                                      │
                              │  PUBLIC SUBNETS (10.20.1.0/24 · 10.20.2.0/24)                                         │
                              │  ┌──────────────────────┐   ┌──────────────────────┐   ┌──────────────────────────┐ │
                              │  │ JENKINS  (t3.medium) │   │ APP  (t3.small)      │   │ MONITORING (t3.small)    │ │
                              │  │ Caddy (HTTPS)        │   │ Caddy (HTTPS)        │   │ Prometheus  Alertmanager │ │
                              │  │ Jenkins (as code)    │──►│ notes-app container  │◄──│ Grafana     Loki         │ │
                              │  │ Docker, Ansible,     │SSH│ node_exporter        │   │ Blackbox exporter        │ │
                              │  │ Trivy, AWS CLI       │   │ cAdvisor, Alloy      │──►│ node_exporter            │ │
                              │  │ = bastion (SSH in)   │   │                      │logs└──────────────────────────┘ │
                              │  └──────────┬───────────┘   └──────────┬───────────┘                                 │
                              │             │ push image               │ pull image / read secrets                   │
                              │             ▼                          ▼                                             │
                              │      ┌─────────────┐          ┌──────────────────┐     ┌──────────────────────────┐ │
                              │      │ Amazon ECR  │          │ SSM Param Store  │     │ CloudWatch → SNS (email) │ │
                              │      └─────────────┘          └──────────────────┘     └──────────────────────────┘ │
                              │                                        │ SQL 5432                                    │
                              │  PRIVATE SUBNETS (10.20.11.0/24 · 10.20.12.0/24)   ▼                                  │
                              │                              ┌─────────────────────────┐                             │
                              │                              │ RDS PostgreSQL 16       │  no internet access         │
                              │                              │ db.t4g.micro            │                             │
                              │                              └─────────────────────────┘                             │
                              └──────────────────────────────────────────────────────────────────────────────────────┘
                                 S3 bucket: Terraform state (versioned, encrypted, locked with a lock file)
```

### 2.1 Addresses (HTTPS without buying a domain)

| Service | Address | Who can reach it |
|---|---|---|
| Notes App | `https://notes.<APP-IP-with-dashes>.sslip.io` | everyone |
| Jenkins | `https://jenkins.<JENKINS-IP-with-dashes>.sslip.io` | everyone (login required) + GitHub webhooks |
| Grafana | `http://localhost:3001` through an SSH tunnel | only you |
| Prometheus | `http://localhost:9091` through an SSH tunnel | only you |

`sslip.io` is a free DNS service: `notes.13-205-81-47.sslip.io` automatically points to `13.205.81.47`. That lets Let's Encrypt issue a real HTTPS certificate without buying a domain. If we buy a domain later, only the host names change.

### 2.2 Network rules (security groups)

| Security group | Allows in | From | Why |
|---|---|---|---|
| `jenkins-sg` | 22 (SSH) | your IP only | bastion: the only SSH door from the internet |
| | 80, 443 | everyone | HTTPS for Jenkins + GitHub webhooks + Let's Encrypt |
| `app-sg` | 80, 443 | everyone | the website |
| | 22 | `jenkins-sg` | Ansible deploys from Jenkins |
| | 9100, 8081, 3000 | `monitoring-sg` | Prometheus scrapes node_exporter, cAdvisor, app `/metrics` |
| `monitoring-sg` | 22 | `jenkins-sg` | Ansible setup |
| | 3100 | `app-sg`, `jenkins-sg` | Alloy sends logs to Loki |
| | 9100 | itself | Prometheus scrapes its own host |
| `rds-sg` | 5432 | `app-sg` only | only the app can talk to the database |

Security groups can refer to **other security groups** instead of IP addresses. "Allow 5432 from `app-sg`" keeps working even when the app server gets a new IP.

---

## 3. The application (Notes App)

| Item | Choice |
|---|---|
| Runtime | Node.js **24 LTS** |
| Web framework | Express |
| Database access + migrations | Knex (query builder + migration files) |
| Features | create, list, update, delete notes; a small HTML page (no build step) |
| Health | `GET /health` (process alive), `GET /ready` (database reachable) |
| Metrics | `GET /metrics` (Prometheus format: requests, latency, errors) via `prom-client` |
| Logs | JSON lines via `pino` (easy to search in Loki) |
| Security headers | `helmet` |
| Tests | Jest + Supertest, against a **real PostgreSQL** container |
| Code style | ESLint |
| Image | multi-stage, `node:24-alpine`, runs as **non-root** user, `HEALTHCHECK` |

### Repository layout (one repo: `notes-devops`)

```text
notes-devops/
├── app/                      Node.js application
│   ├── src/                  server, routes, db, metrics
│   ├── migrations/           Knex migrations
│   ├── tests/                Jest tests
│   ├── Dockerfile
│   └── package.json
├── compose.yml               local development: app + postgres
├── compose.ci.yml            CI tests: tests + postgres (same command locally and in Jenkins)
├── Jenkinsfile               the pipeline
├── infra/
│   ├── terraform/
│   │   ├── bootstrap/        S3 state bucket + ECR (kept between sessions)
│   │   ├── modules/          network, security, compute, database, ...
│   │   └── envs/prod/        uses the modules (destroyed after each session)
│   └── ansible/
│       ├── inventory/        dynamic inventory (finds servers by AWS tags)
│       ├── roles/            common, docker, caddy, jenkins, app, monitoring, agents
│       └── playbooks/        site.yml (setup), deploy.yml (release), rollback via deploy.yml
├── monitoring/               Prometheus, Alertmanager, Loki, Grafana dashboards (as code)
└── docs/                     this design + step journal → final PDF
```

---

## 4. The pipeline

```text
 Developer             GitHub                     Jenkins (multibranch)                                 AWS
 ─────────             ──────                     ─────────────────────                                 ───
 feature/x ──push──►  PR opened ──webhook──►  [1] Checkout
                                              [2] Lint            ESLint + terraform fmt/validate
                                              [3] Test            compose.ci.yml: Jest + real PostgreSQL
                                              [4] Build image     tag = git commit SHA
                                              [5] Scan image      Trivy: fail on fixable HIGH/CRITICAL
                      ✅ status check on PR ◄──  (PR builds stop here)
 merge PR ─────────►  main ──webhook──────►   [1]–[5] again, then (main only):
                                              [6] Push            → Amazon ECR
                                              [7] Deploy          ansible-playbook deploy.yml  ─────────►  app server:
                                                                                                         migrate DB, restart container
                                              [8] Smoke test      curl https://notes.../ready + /api/notes
                                              [9] Record          SSM: current image tag = this SHA
                                              ✖ if [7] or [8] fails → Rollback: deploy previous tag
                                              ✉ email: success / failure / rolled back
```

**Branch protection on `main`:** changes only via Pull Request, and the Jenkins check must pass. This is what makes CI meaningful in a team: nobody can push broken code straight to production.

---

## 5. Monitoring and alerts

| What | Tool | Where it runs |
|---|---|---|
| Server CPU, RAM, disk, network | node_exporter | every server |
| Container CPU, RAM per container | cAdvisor | app server |
| App requests, latency, errors | app `/metrics` (prom-client) | app container |
| Is the website up from outside? | Blackbox exporter (HTTPS probe of `/ready`) | monitoring server |
| Logs (app + system) | Grafana **Alloy** → **Loki** | Alloy on app/Jenkins, Loki on monitoring |
| Database CPU, storage, connections | CloudWatch (RDS metrics), shown in Grafana; **CloudWatch alarm → SNS → email** | AWS |
| Storage + rules | Prometheus (15 days) | monitoring server |
| Graphs | Grafana: dashboards and data sources **provisioned as code** | monitoring server |
| Alerts | Alertmanager → **email** | monitoring server |

**Alert rules (first set)**

| Alert | Fires when | Why it matters |
|---|---|---|
| `InstanceDown` | a target is unreachable for 1 min | a server or exporter died |
| `AppDown` | HTTPS probe of `/ready` fails for 1 min | users can't use the site |
| `HighErrorRate` | more than 5% of requests return 5xx for 5 min | the app is broken for many users |
| `HighLatency` | 95% of requests take longer than 1 s for 5 min | the app is slow |
| `HostHighCpu` | CPU above 85% for 10 min | the server is overloaded |
| `HostLowMemory` | less than 10% memory free for 5 min | about to crash or swap heavily |
| `HostDiskFull` | disk above 85% | old images / logs filling the disk |
| RDS CPU / storage | CloudWatch: CPU above 80%, free storage below 2 GB | database trouble |

---

## 6. Decisions (with reasons)

Each decision: **what we chose**, **what else we could have chosen**, **why**.

### D1. Node.js 24 LTS (not Node 26)
- **Options:** Node 22 (older, maintenance), **Node 24** (LTS, supported until April 2028), Node 26 (becomes LTS on 28 Oct 2026).
- **Why 24:** proven, supported for 18 more months, every library supports it. Upgrading to 26 later through the pipeline is a good exercise.

### D2. Express + Knex (not NestJS, not Prisma)
- **Options:** Express, Fastify, NestJS · raw `pg`, Knex, Prisma, Sequelize.
- **Why:** Express is the most common and the smallest to read. Knex gives plain JavaScript migrations (like Laravel migrations) without the extra binary engine Prisma needs, which is simpler for Docker images and different CPU types.

### D3. Tests against a real PostgreSQL (not SQLite)
- **Beginner:** tests used SQLite in memory.
- **Why change:** production uses PostgreSQL. Some bugs only appear on the real database (types, constraints). `compose.ci.yml` starts PostgreSQL next to the tests, and the **same command** runs on the Mac and in Jenkins.

### D4. One repository (monorepo)
- **Options:** separate repos for app and infrastructure, or one repo.
- **Why one:** fewer moving parts while learning; one place for code, infra and docs. The Jenkinsfile only builds and deploys when `app/` changes. (Big teams often split repos; easy to do later.)

### D5. Own VPC with public + private subnets, no NAT gateway
- **Options:** default VPC (beginner) · own VPC with NAT gateway · own VPC without NAT.
- **Why:** the database lives in **private** subnets (no route to the internet), which is the main safety benefit. Servers stay in **public** subnets so they can download packages without a NAT gateway (a NAT gateway costs roughly $30+/month even when idle).
- **Trade-off:** servers have public IPs; security groups do the protection.

### D6. Three servers: app, Jenkins, monitoring
- **Options:** everything on one server · two servers (monitoring on the Jenkins host) · three.
- **Why three:** monitoring must survive when the thing it watches breaks; Jenkins builds use a lot of CPU and RAM and must not slow down the website.
- **Cheaper option:** put monitoring on the Jenkins host (2 servers). Same design otherwise.

### D7. Amazon RDS for PostgreSQL (not a container)
- **Options:** PostgreSQL container on the app server (beginner) · RDS.
- **Why:** backups, patching and storage are handled by AWS; data is not lost when the app server is replaced; it is what companies use.
- **Settings for learning:** `db.t4g.micro`, 20 GB, single AZ, encrypted, 1-day backups, deletion protection **off**, no final snapshot (data is demo data, deleted each session).

### D8. Terraform: modules + remote state in S3 with native locking
- **Options:** one big file · modules · local state (beginner) · S3 + DynamoDB lock table · **S3 with `use_lockfile`**.
- **Why:** modules make each part (network, database...) small and reusable. Remote state means the state survives if the Mac is lost, and a **lock file** stops two `apply` runs at the same time. Terraform's S3 backend now supports native locking (`use_lockfile = true`) and marks DynamoDB locking as deprecated, so no DynamoDB table is needed.

### D9. Two Terraform stacks: `bootstrap` (kept) and `prod` (destroyed each session)
- **Why:** the state bucket and the ECR repository must exist **before** and **after** everything else, and cost almost nothing. VPC, servers and RDS cost per hour, so they are destroyed after each practice session and recreated with one `apply`.

### D10. Ansible for server setup and deploys
- **Options:** keep `user-data.sh` + manual commands · Ansible · Chef/Puppet.
- **Why Ansible:** agentless (only SSH), YAML, easy to read, idempotent (running it twice changes nothing the second time). Terraform **creates** servers; Ansible **configures** them.
- **User-data is reduced** to the minimum (nothing, or only Python for Ansible).

### D11. Ansible dynamic inventory (find servers by AWS tags)
- **Options:** a hand-written `hosts.ini` · a file generated by Terraform · **dynamic inventory** (`amazon.aws.aws_ec2`).
- **Why:** IP addresses change after every `apply`. The dynamic inventory asks AWS "which servers have tag `Role=app`?", so nothing needs updating.

### D12. Jenkins host = bastion; no public SSH on app and monitoring
- **Options:** SSH from home IP to every server (beginner) · bastion · SSM Session Manager only.
- **Why:** only one server has SSH open to the internet (and only to your IP). Others are reached through it (`ssh -J` / ProxyJump). Ansible on Jenkins reaches them over private IPs. AWS SSM Session Manager stays available as an emergency door (no open port at all).

### D13. Amazon ECR + IAM roles (no registry password)
- **Options:** Docker Hub with a token (beginner) · ECR.
- **Why:** the Jenkins server's **IAM role** may push, the app server's role may pull. No password exists that could leak. A lifecycle policy keeps only the last 15 images.

### D14. Image tag = git commit SHA (not `latest`)
- **Why:** every running version points to an exact commit. Rollback = deploy the previous SHA. `latest` changes meaning all the time and makes rollbacks guesswork.

### D15. Secrets in SSM Parameter Store (not Secrets Manager, not files)
- **Options:** `.env` file copied by hand (beginner) · AWS Secrets Manager · **SSM Parameter Store** (SecureString).
- **Why:** encrypted, access controlled by IAM roles, and standard parameters are free (Secrets Manager charges per secret per month). Terraform creates the database password (random) and stores it; Ansible reads it at deploy time and writes `.env` with permissions `0600` on the app server.
- **Note:** Terraform state also contains that password, so the state bucket is encrypted and private.

### D16. Jenkins installed natively by Ansible and configured as code
- **Options:** Jenkins in Docker (beginner) · native install.
- **Why native:** pipeline steps can run inside Docker containers cleanly (`agent { docker ... }`) without "Docker inside Docker" path problems.
- **As code:** plugins from a `plugins.txt` list, settings/credentials/jobs from **JCasC** (Jenkins Configuration as Code) YAML. A new Jenkins server is fully configured by one Ansible run, with no clicking.

### D17. GitHub webhook + multibranch pipeline + branch protection
- **Options:** polling every 2 min (beginner) · webhook.
- **Why:** builds start within seconds; every branch and Pull Request gets its own build; GitHub shows ✅/❌ on the PR, and `main` refuses merges until the check passes.

### D18. Trivy image scan in the pipeline
- **Why:** finds known vulnerabilities in the OS packages and npm libraries inside the image. The build fails on **HIGH/CRITICAL issues that have a fix**, so we fix what we can without being blocked by unfixable noise.
- **Not now:** SonarQube needs a large server (2+ GB RAM for itself). ESLint + Trivy + `npm audit` cover the basics; SonarQube/SonarCloud is a later add-on.

### D19. Smoke test + automatic rollback
- **Why:** tests prove the code works; the smoke test proves **the deployed site** works (real database, real HTTPS). If it fails, Jenkins redeploys the previous image tag automatically and emails you.

### D20. HTTPS with Caddy + Let's Encrypt + sslip.io (no load balancer yet)
- **Options:** no HTTPS (beginner) · Application Load Balancer + ACM certificate (needs a domain, ~$16+/month) · **Caddy** on each server.
- **Why:** Caddy gets and renews free certificates automatically with a few lines of config; sslip.io gives a host name without buying a domain. The load balancer becomes useful at the advanced level (several app servers, zero-downtime deploys, ECS).

### D21. Grafana Alloy for logs (not Promtail)
- **Why:** Promtail reached end of life in March 2026 and no longer gets fixes; Grafana Alloy is its replacement and sends logs to Loki.

### D22. Alerts by email: Alertmanager (servers/app) + CloudWatch/SNS (RDS)
- **Why:** Prometheus can't see inside RDS hosts; CloudWatch can. Alertmanager sends email via SMTP (e.g. a Gmail **App Password**, stored in SSM). SNS sends CloudWatch alarms to the same inbox.

### D23. Terraform apply stays manual; the pipeline only checks Terraform
- **Why:** infrastructure changes can delete things; a human reads `plan` first. The pipeline runs `terraform fmt -check` and `terraform validate` so broken Terraform code is caught early.

---

## 7. Cost (approximate, Mumbai region)

| Item | ≈ per hour (USD) |
|---|---|
| Jenkins `t3.medium` | 0.045 |
| App `t3.small` + Monitoring `t3.small` | 0.045 |
| RDS `db.t4g.micro` | 0.02 |
| Disks (3 × 20 GB + 20 GB RDS) | 0.01 |
| Public IPv4 addresses (3) | 0.015 |
| **Total while running** | **≈ 0.13–0.15** |

- One 4-hour session ≈ **$0.6**. Left running for a month ≈ **$100**: always `terraform destroy` the `prod` stack after practice.
- Kept between sessions (`bootstrap`): S3 state + ECR images: a few cents per month.
- Prices are estimates; check the AWS Pricing Calculator and keep the **budget alarm** on.

---

## 8. Build order (phases)

| Phase | What we build | Done when |
|---|---|---|
| 1 | Notes App locally: Express, Knex, tests, Dockerfile, `compose.yml`, `compose.ci.yml` | app runs at `localhost`, tests pass in Docker |
| 2 | GitHub repo `notes-devops`, branch protection | `main` accepts only PRs |
| 3 | Terraform `bootstrap`: S3 state bucket + ECR | state stored in S3 |
| 4 | Terraform `prod`: VPC, subnets, security groups, IAM roles, 3 EC2, RDS, SSM parameters, CloudWatch alarms + SNS | `apply` creates everything; `destroy` removes it |
| 5 | Ansible: dynamic inventory, roles `common`, `docker`, `caddy`, bastion access | one command configures all servers |
| 6 | Jenkins as code (native, JCasC, plugins), HTTPS, GitHub webhook, multibranch job | a PR shows a Jenkins ✅ |
| 7 | Full pipeline: lint, test, build, scan, push ECR, Ansible deploy, smoke test, rollback, email | merge → live in minutes; a broken deploy rolls back by itself |
| 8 | Monitoring server: Prometheus, Alertmanager, Grafana (as code), Loki + Alloy, Blackbox, cAdvisor, app metrics | dashboards show app + servers; stopping the app sends an email |
| 9 | Intermediate PDF + teardown | PDF in `docs/`; `terraform destroy` |

Every phase is written to `docs/` as we go (commands, files, errors and fixes), so the final PDF reflects what we really did.

---

## 9. Open questions (to confirm before Phase 1)

1. **Servers:** 3 servers (recommended) or 2 (monitoring on the Jenkins host, cheaper)?
2. **Alert email:** which email address? For Gmail we need a Gmail **App Password** (Google account → Security → 2-Step Verification on → App passwords).
3. **Domain:** use free `sslip.io` names (default), or do you have a domain?
4. **GitHub repo name:** `notes-devops` (public), OK?
