# Phase 7: The full pipeline (build, scan, push, deploy, smoke test, rollback)

**Goal:** merging a PR into `main` is the **only** step needed to release. Jenkins builds the image, scans it for security problems, stores it in ECR, deploys it to the app server, tests it from the internet, and **switches back to the previous version by itself** if anything goes wrong.

**Done when:** a merge puts the new version live (the version shown by `/health` = the Git commit), and a deliberately broken release is rolled back automatically while the site stays up.

---

## 7.1 The whole flow

```text
 git merge into main
        │  webhook
        ▼
 JENKINS (main branch)
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │ 1 Lint & Test     docker compose -f compose.ci.yml run tests   (also on PRs)  │
 │ 2 Build image     docker build --target production  tag = full commit SHA     │
 │ 3 Security scan   trivy image  → fail on CRITICAL with a fix available        │
 │ 4 Push to ECR     docker push (login by IAM role, no password)                │
 │ 5 Deploy          ansible-playbook deploy.yml ─────────────┐                  │
 │                   aws ssm put-parameter image_tag=<sha>     │ (only if OK)    │
 └─────────────────────────────────────────────────────────────┼─────────────────┘
                                                               │ SSH (deploy key, private IP)
                                                               ▼
 APP SERVER  /opt/notes
   .env (from SSM: DB host/user/password)   rds-ca.pem   compose.yml (image:<sha>)
   docker compose pull → run migrations → up -d
   wait for /ready (database OK)            ┐
   from Jenkins: https://notes.<ip>.sslip.io │  any failure
     /health shows <sha>, /api/notes 200     ┘     │
                                                   ▼
                                    ROLLBACK: compose.yml (image:<previous sha>) → up -d
                                    → wait for /ready → build turns RED
```

| Branch / PR | Stages |
|---|---|
| Pull request (`PR-N`) | 1 only (and GitHub requires it ✓) |
| `main` | 1 → 5 |
| other branches without a PR | 1 only |

---

## 7.2 New words

| Word | Simple meaning |
|---|---|
| **Container registry** | a storage for Docker images. **ECR** = Amazon's private registry |
| **Image tag** | the name of one version of an image (`notes-app:<tag>`). We use the **full Git commit SHA** |
| **Immutable tags** | ECR refuses to overwrite a tag, so a tag always means exactly one image |
| **Vulnerability scan** | checks the packages inside an image against a database of known security holes (**CVE**s) |
| **CVE** | "Common Vulnerabilities and Exposures": a public ID for a known security hole, e.g. CVE-2026-33634 |
| **Severity** | LOW / MEDIUM / HIGH / CRITICAL: how bad a hole is |
| **"fixed" / "unfixed"** | whether a patched package version exists yet |
| **Migration** | a script that changes the database structure (create table, add column) |
| **Health check / readiness** | `/health` = the process is alive; `/ready` = it can also reach the database |
| **Smoke test** | a quick check **after** a deploy that the most important things work ("does it smoke when switched on?") |
| **Rollback** | going back to the previous working version |
| **Supply-chain attack** | attackers put malware into a tool or library many people download (the tool, not your code, is attacked) |
| **Credential helper** | a small program Docker asks for registry logins; ours gets them from the server's IAM role |

---

## 7.3 Decisions in this phase

| # | Decision | Why |
|---|---|---|
| P7-1 | Deploy stages run **only on `main`** (`when { branch 'main' }`) | PRs must never change production; only reviewed, merged code is released |
| P7-2 | Image tag = **full 40-character commit SHA** | one ID links code, image and running version; no confusion between similar short IDs |
| P7-3 | `docker build --pull` | always start from the newest `node:24-alpine` (security patches) |
| P7-4 | `GIT_SHA` build argument → `APP_VERSION` → `/health` | the smoke test can prove the **new** version is the one answering |
| P7-5 | **Trivy** as the scanner | free, fast, widely used, scans OS packages and npm packages |
| P7-6 | Trivy **pinned to 0.75.0** and **checksum-verified**; not the newest release | in March 2026 attackers published a malicious Trivy **0.69.4** and replaced trivy-action tags (CVE-2026-33634). Pinning a version that has been public for a few weeks, and checking its checksum, means a newly hijacked release can't silently enter our server |
| P7-7 | Fail only on **CRITICAL** with a fix available (`--ignore-unfixed`); show HIGH too | blocks the dangerous, fixable problems; doesn't block releases for holes nobody can fix yet. Stricter teams also fail on HIGH |
| P7-8 | Push skipped if the tag already exists in ECR | ECR tags are immutable; re-running a build for the same commit would otherwise fail |
| P7-9 | ECR login with **amazon-ecr-credential-helper** (Jenkins and app) | no `docker login`, no password saved on disk; the IAM role is used every time |
| P7-10 | Ansible **runs on the Jenkins server** (`/opt/ansible` venv) with `use_bastion=false` | Jenkins is inside the VPC and reaches the app server on its private IP directly |
| P7-11 | Deploy key written from SSM to `/var/lib/jenkins/.ssh/deploy_key` (0600) | the key Terraform generated in Phase 4; app server already trusts it (cloud-init) |
| P7-12 | `.env` built at deploy time from SSM, mode **0600**, owner root | the database password never touches Git, Jenkins logs or the image |
| P7-13 | Password written in **single quotes** in `.env` | Compose doesn't interpret anything inside single quotes (safe for `#`, `=`, `!`) |
| P7-14 | TLS to RDS **verified** with the RDS certificate bundle | encrypted **and** proven to be our real database (`rejectUnauthorized: true`) |
| P7-15 | Migrations run **before** the switch, with the new image | the new code finds the tables it needs. Rule: migrations must stay compatible with the previous version (only add, never drop in the same release), so a rollback still works |
| P7-16 | Ansible **block / rescue** for the rollback | try the deploy; if any step fails, the rescue part runs automatically |
| P7-17 | Two checks: `/ready` on the server **and** HTTPS from outside | `/ready` proves app + database; the outside test proves DNS + Caddy + certificate + the new version |
| P7-18 | After a rollback the build still **fails** | someone must look; a green build would hide the problem |
| P7-19 | SSM `image_tag` updated **only after** a successful deploy | it always names the version that really works (= the next rollback target) |
| P7-20 | Old images cleaned (`docker image prune --filter until=168h`) | keeps the disk from filling; a missing previous image is simply pulled again during a rollback |
| P7-21 | **No email** (user's choice) | failures are visible as a red build in Jenkins and a red ✗ on GitHub; alerting comes with monitoring (Phase 8) |

---

## 7.4 New and changed files

```text
Jenkinsfile                                         5 stages
infra/terraform/envs/prod/main.tf                   + SSM ecr_repository_url, alert_email
infra/ansible/playbooks/deploy.yml                  NEW
infra/ansible/playbooks/site.yml                    + ecr_login for the jenkins user
infra/ansible/roles/jenkins/tasks/tools.yml         NEW  AWS CLI, Trivy, Ansible venv, deploy key
infra/ansible/roles/jenkins/{defaults,tasks/main.yml,templates/jenkins.yaml.j2}   + tools, env vars
infra/ansible/roles/ecr_login/                      NEW  credential helper
infra/ansible/roles/notes_app/                      NEW  the deploy with rollback
```

---

## 7.5 The `Jenkinsfile`

<sub>File: `Jenkinsfile`</sub>

```groovy
pipeline {
  agent any

  options {
    timestamps()
    ansiColor('xterm')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timeout(time: 30, unit: 'MINUTES')
  }

  environment {
    CI_PROJECT = "ci-${env.BRANCH_NAME.toLowerCase().replaceAll('[^a-z0-9]', '-')}-${env.BUILD_NUMBER}"
  }

  stages {
    stage('Lint & Test') {
      steps {
        sh 'docker compose -p "$CI_PROJECT" -f compose.ci.yml run --rm --build tests'
      }
    }

    stage('Build image') {
      when { branch 'main' }
      steps {
        script {
          env.IMAGE_TAG = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
          env.IMAGE = "${env.ECR_REPOSITORY_URL}:${env.IMAGE_TAG}"
        }
        sh 'docker build --pull --target production --build-arg GIT_SHA="$IMAGE_TAG" -t "$IMAGE" app'
      }
    }

    stage('Security scan') {
      when { branch 'main' }
      steps {
        sh 'trivy image --no-progress --scanners vuln --severity HIGH,CRITICAL --exit-code 0 "$IMAGE"'
        sh 'trivy image --no-progress --scanners vuln --severity CRITICAL --ignore-unfixed --exit-code 1 "$IMAGE"'
      }
    }

    stage('Push to ECR') {
      when { branch 'main' }
      steps {
        sh '''
          REPO_NAME="${ECR_REPOSITORY_URL#*/}"
          if aws ecr describe-images --repository-name "$REPO_NAME" --image-ids imageTag="$IMAGE_TAG" >/dev/null 2>&1; then
            echo "Image $IMAGE_TAG is already in ECR - not pushing again"
          else
            docker push "$IMAGE"
          fi
        '''
      }
    }

    stage('Deploy') {
      when { branch 'main' }
      steps {
        dir('infra/ansible') {
          sh '"$ANSIBLE_PLAYBOOK" playbooks/deploy.yml -e image_tag="$IMAGE_TAG" -e use_bastion=false'
        }
        sh 'aws ssm put-parameter --name "$SSM_PREFIX/image_tag" --type String --value "$IMAGE_TAG" --overwrite'
      }
    }
  }

  post {
    success {
      script {
        if (env.BRANCH_NAME == 'main') {
          echo "Deployed ${env.IMAGE_TAG}"
        }
      }
    }
    always {
      sh 'docker compose -p "$CI_PROJECT" -f compose.ci.yml down -v --rmi local --remove-orphans || true'
      sh 'if [ -n "$IMAGE" ]; then docker image rm "$IMAGE" || true; fi'
      cleanWs()
    }
  }
}
```

| Stage / part | What happens |
|---|---|
| `Lint & Test` | same as Phase 6 |
| `Build image` | `git rev-parse HEAD` = the commit SHA → `IMAGE_TAG`. `IMAGE` = `<ECR URL>:<sha>`. Builds only the `production` stage of the Dockerfile from the `app` folder |
| `Security scan` | 1st `trivy`: prints all HIGH and CRITICAL findings, never fails (`--exit-code 0`). 2nd: fails (`--exit-code 1`) if a CRITICAL with a fix exists. `--scanners vuln` = only vulnerabilities (no secret/licence scanning) |
| `Push to ECR` | `${ECR_REPOSITORY_URL#*/}` = everything after the first `/` = the repository name `notes-app`. `describe-images` checks whether the tag exists already |
| `Deploy` | runs the playbook from `infra/ansible` (so `ansible.cfg` is found), then records the tag in SSM |
| `post success` | prints the deployed version |
| `post always` | test containers down, local image removed, workspace cleaned |

The environment variables (`ECR_REPOSITORY_URL`, `SSM_PREFIX`, `AWS_REGION`, `ANSIBLE_PLAYBOOK`, `ANSIBLE_PRIVATE_KEY_FILE`, ...) come from JCasC (`globalNodeProperties`), so the Jenkinsfile contains no account numbers or paths.

---

## 7.6 Tools on the Jenkins server

<sub>File: `infra/ansible/roles/jenkins/tasks/tools.yml`</sub>

```yaml
# Tools the pipeline uses on the Jenkins server

- name: Install packages for the tools
  ansible.builtin.apt:
    name:
      - unzip
      - python3-venv
    state: present

# ---------- AWS CLI v2 (push the deployed tag to SSM) ----------

- name: Check if the AWS CLI is installed
  ansible.builtin.stat:
    path: /usr/local/bin/aws
  register: jenkins_awscli

- name: Download the AWS CLI v2
  ansible.builtin.get_url:
    url: https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
    dest: /tmp/awscliv2.zip
    mode: "0644"
  when: not jenkins_awscli.stat.exists

- name: Unpack the AWS CLI v2
  ansible.builtin.unarchive:
    src: /tmp/awscliv2.zip
    dest: /tmp
    remote_src: true
  when: not jenkins_awscli.stat.exists

- name: Install the AWS CLI v2
  ansible.builtin.command:
    cmd: /tmp/aws/install
    creates: /usr/local/bin/aws

# ---------- Trivy (pinned version, checksum checked) ----------

- name: Create the Trivy folder for this version
  ansible.builtin.file:
    path: "/opt/trivy-{{ jenkins_trivy_version }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Download Trivy and check its checksum
  ansible.builtin.get_url:
    url: "{{ jenkins_trivy_base_url }}/trivy_{{ jenkins_trivy_version }}_Linux-64bit.tar.gz"
    dest: "/opt/trivy-{{ jenkins_trivy_version }}/trivy.tar.gz"
    checksum: "sha256:{{ jenkins_trivy_base_url }}/trivy_{{ jenkins_trivy_version }}_checksums.txt"
    mode: "0644"

- name: Unpack Trivy
  ansible.builtin.unarchive:
    src: "/opt/trivy-{{ jenkins_trivy_version }}/trivy.tar.gz"
    dest: "/opt/trivy-{{ jenkins_trivy_version }}"
    remote_src: true
    include:
      - trivy
    creates: "/opt/trivy-{{ jenkins_trivy_version }}/trivy"

- name: Make this Trivy version the active one
  ansible.builtin.file:
    src: "/opt/trivy-{{ jenkins_trivy_version }}/trivy"
    dest: /usr/local/bin/trivy
    state: link

# ---------- Ansible on the Jenkins server (for deploys) ----------

- name: Install Ansible and boto3 in a virtual environment
  ansible.builtin.pip:
    name:
      - ansible
      - boto3
    virtualenv: "{{ jenkins_ansible_venv }}"
    virtualenv_command: python3 -m venv

# ---------- SSH key Ansible uses to reach the app server ----------

- name: Create the .ssh folder of the jenkins user
  ansible.builtin.file:
    path: "{{ jenkins_home }}/.ssh"
    state: directory
    owner: jenkins
    group: jenkins
    mode: "0700"

- name: Write the deploy key from SSM
  ansible.builtin.copy:
    dest: "{{ jenkins_deploy_key }}"
    content: "{{ lookup('amazon.aws.ssm_parameter', jenkins_ssm_prefix ~ '/deploy_ssh_private_key', region=jenkins_aws_region) | trim }}\n"
    owner: jenkins
    group: jenkins
    mode: "0600"
  no_log: true
```

| Part | Why |
|---|---|
| AWS CLI v2 | `aws ecr describe-images`, `aws ssm put-parameter` in the pipeline |
| Trivy folder per version + symlink | upgrading = change one variable; the old version stays until removed |
| `get_url` with `checksum: sha256:<url of checksums.txt>` | Ansible downloads the official checksum list and refuses the file if it doesn't match |
| `unarchive include: [trivy]` | take only the program out of the archive |
| Ansible in `/opt/ansible` | its own Python environment with `ansible` (includes amazon.aws) and `boto3` |
| deploy key | `lookup` reads it from SSM on the control node; `| trim` + `\n` because an SSH key file must end with a line break |

Added to JCasC (global environment variables for every build):

```yaml
  globalNodeProperties:
    - envVars:
        env:
          - key: "AWS_REGION"
            value: "ap-south-1"
          - key: "SSM_PREFIX"
            value: "/notes-devops/prod"
          - key: "ECR_REPOSITORY_URL"
            value: "<account>.dkr.ecr.ap-south-1.amazonaws.com/notes-app"
          - key: "ANSIBLE_PRIVATE_KEY_FILE"
            value: "/var/lib/jenkins/.ssh/deploy_key"
          - key: "ANSIBLE_PLAYBOOK"
            value: "/opt/ansible/bin/ansible-playbook"
          ...
```

---

## 7.7 Role `ecr_login`

<sub>File: `infra/ansible/roles/ecr_login/defaults/main.yml`</sub>

```yaml
ecr_login_ssm_prefix: /notes-devops/prod
ecr_login_aws_region: ap-south-1
ecr_login_repository_url: "{{ lookup('amazon.aws.ssm_parameter', ecr_login_ssm_prefix ~ '/ecr_repository_url', region=ecr_login_aws_region) }}"
ecr_login_registry: "{{ ecr_login_repository_url.split('/')[0] }}"

ecr_login_users:
  - name: root
    home: /root
```

<sub>File: `infra/ansible/roles/ecr_login/tasks/main.yml`</sub>

```yaml
- name: Install the Amazon ECR credential helper
  ansible.builtin.apt:
    name: amazon-ecr-credential-helper
    state: present

- name: Create the Docker config folder
  ansible.builtin.file:
    path: "{{ item.home }}/.docker"
    state: directory
    owner: "{{ item.name }}"
    group: "{{ item.name }}"
    mode: "0700"
  loop: "{{ ecr_login_users }}"
  loop_control:
    label: "{{ item.name }}"

- name: Let Docker log in to ECR with the server's IAM role
  ansible.builtin.copy:
    dest: "{{ item.home }}/.docker/config.json"
    content: "{{ {'credHelpers': {ecr_login_registry: 'ecr-login'}} | to_nice_json }}\n"
    owner: "{{ item.name }}"
    group: "{{ item.name }}"
    mode: "0600"
  loop: "{{ ecr_login_users }}"
  loop_control:
    label: "{{ item.name }}"
```

The resulting `~/.docker/config.json`:

```json
{
    "credHelpers": {
        "725072160791.dkr.ecr.ap-south-1.amazonaws.com": "ecr-login"
    }
}
```

= "for this registry, ask the program `docker-credential-ecr-login`". That program asks the **instance metadata service** for the server's temporary IAM credentials and gets a 12-hour ECR token. Jenkins' role may push; the app's role may only pull (Phase 4).

---

## 7.8 Role `notes_app`: the deploy

<sub>File: `infra/ansible/playbooks/deploy.yml`</sub>

```yaml
- name: Deploy the Notes app
  hosts: app
  become: true
  roles:
    - ecr_login
    - notes_app
```

<sub>File: `infra/ansible/roles/notes_app/defaults/main.yml`</sub>

```yaml
notes_app_image_tag: "{{ image_tag | default('') }}"

notes_app_dir: /opt/notes
notes_app_ssm_prefix: /notes-devops/prod
notes_app_aws_region: ap-south-1
notes_app_rds_ca_url: https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
notes_app_public_url: "https://{{ caddy_site }}"

notes_app_ready_retries: 20
notes_app_ready_delay: 3
```

<sub>File: `infra/ansible/roles/notes_app/templates/env.j2`</sub>

```jinja
# Managed by Ansible - values come from SSM Parameter Store
NODE_ENV=production
PORT=3000
LOG_LEVEL=info

DB_HOST={{ notes_app_settings.db_host }}
DB_PORT={{ notes_app_settings.db_port }}
DB_NAME={{ notes_app_settings.db_name }}
DB_USER={{ notes_app_settings.db_user }}
DB_PASSWORD='{{ notes_app_settings.db_password }}'
DB_SSL=true
DB_SSL_CA_FILE=/certs/rds-ca.pem
```

<sub>File: `infra/ansible/roles/notes_app/templates/compose.yml.j2`</sub>

```jinja
# Managed by Ansible - deployed version: {{ notes_app_tag }}
name: notes

services:
  app:
    image: "{{ notes_app_settings.ecr_repository_url }}:{{ notes_app_tag }}"
    env_file: .env
    ports:
      - "3000:3000"
    volumes:
      - ./rds-ca.pem:/certs/rds-ca.pem:ro
    restart: unless-stopped
```

| compose.yml | Why |
|---|---|
| `name: notes` | fixed project name, so every deploy manages the same container |
| `image: <ECR>:<sha>` | exactly the version being deployed |
| `ports: "3000:3000"` | Caddy reaches it on 127.0.0.1:3000; Prometheus (Phase 8) on the private IP. The security group allows 3000 only from the monitoring server |
| volume `rds-ca.pem` read-only | the certificate bundle for checking the database |
| `restart: unless-stopped` | starts again after a crash or a reboot |

<sub>File: `infra/ansible/roles/notes_app/tasks/main.yml`</sub>

```yaml
- name: Check the image tag (a full git commit SHA)
  ansible.builtin.assert:
    that: notes_app_image_tag is match('^[0-9a-f]{40}$')
    fail_msg: "Run with -e image_tag=<40-character git commit SHA>, got '{{ notes_app_image_tag }}'"
    quiet: true

- name: Read the settings from SSM Parameter Store
  ansible.builtin.set_fact:
    notes_app_settings: "{{ dict(notes_app_names | zip(notes_app_values)) }}"
  vars:
    notes_app_names: [db_host, db_port, db_name, db_user, db_password, ecr_repository_url, image_tag]
    notes_app_paths: "{{ notes_app_names | map('regex_replace', '^', notes_app_ssm_prefix ~ '/') | list }}"
    notes_app_values: "{{ query('amazon.aws.ssm_parameter', *notes_app_paths, region=notes_app_aws_region) }}"
  no_log: true

- name: Remember the version that is running now
  ansible.builtin.set_fact:
    notes_app_previous_tag: "{{ notes_app_settings.image_tag }}"

- name: Show what is deployed
  ansible.builtin.debug:
    msg: "Deploying {{ notes_app_image_tag[:12] }} (running now: {{ notes_app_previous_tag[:12] }})"

- name: Create the app folder
  ansible.builtin.file:
    path: "{{ notes_app_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0750"

- name: Download the RDS certificate bundle (to verify the database's TLS certificate)
  ansible.builtin.get_url:
    url: "{{ notes_app_rds_ca_url }}"
    dest: "{{ notes_app_dir }}/rds-ca.pem"
    owner: root
    group: root
    mode: "0644"

- name: Write the app settings (.env)
  ansible.builtin.template:
    src: env.j2
    dest: "{{ notes_app_dir }}/.env"
    owner: root
    group: root
    mode: "0600"
  no_log: true

- name: Deploy the new version (rolls back by itself if it fails)
  block:
    - name: Write compose.yml with the new image
      ansible.builtin.template:
        src: compose.yml.j2
        dest: "{{ notes_app_dir }}/compose.yml"
        owner: root
        group: root
        mode: "0644"
      vars:
        notes_app_tag: "{{ notes_app_image_tag }}"

    - name: Pull the new image from ECR
      ansible.builtin.command:
        cmd: docker compose pull
        chdir: "{{ notes_app_dir }}"
      changed_when: true

    - name: Run database migrations with the new image
      ansible.builtin.command:
        cmd: docker compose run --rm app npm run migrate
        chdir: "{{ notes_app_dir }}"
      register: notes_app_migrate
      changed_when: "'Already up to date' not in notes_app_migrate.stdout"

    - name: Start the new version
      ansible.builtin.command:
        cmd: docker compose up -d --remove-orphans
        chdir: "{{ notes_app_dir }}"
      changed_when: true

    - name: Wait until the app is ready (database connected)
      ansible.builtin.uri:
        url: http://127.0.0.1:3000/ready
        status_code: 200
      register: notes_app_ready
      until: notes_app_ready.status == 200
      retries: "{{ notes_app_ready_retries }}"
      delay: "{{ notes_app_ready_delay }}"

    - name: Smoke test from outside - HTTPS shows the new version
      ansible.builtin.uri:
        url: "{{ notes_app_public_url }}/health"
        return_content: true
      register: notes_app_health
      until: notes_app_health.json is defined and notes_app_health.json.version == notes_app_image_tag
      retries: 5
      delay: 3
      delegate_to: localhost
      become: false

    - name: Smoke test from outside - the notes API answers
      ansible.builtin.uri:
        url: "{{ notes_app_public_url }}/api/notes"
        status_code: 200
      delegate_to: localhost
      become: false

  rescue:
    - name: Deploy failed
      ansible.builtin.debug:
        msg: "Deploy of {{ notes_app_image_tag[:12] }} failed at: {{ ansible_failed_task.name }}"

    - name: Roll back to the previous version
      when: notes_app_previous_tag is match('^[0-9a-f]{40}$')
      block:
        - name: Write compose.yml with the previous image
          ansible.builtin.template:
            src: compose.yml.j2
            dest: "{{ notes_app_dir }}/compose.yml"
            owner: root
            group: root
            mode: "0644"
          vars:
            notes_app_tag: "{{ notes_app_previous_tag }}"

        - name: Start the previous version
          ansible.builtin.command:
            cmd: docker compose up -d --remove-orphans
            chdir: "{{ notes_app_dir }}"
          changed_when: true

        - name: Wait until the previous version is ready
          ansible.builtin.uri:
            url: http://127.0.0.1:3000/ready
            status_code: 200
          register: notes_app_rollback_ready
          until: notes_app_rollback_ready.status == 200
          retries: "{{ notes_app_ready_retries }}"
          delay: "{{ notes_app_ready_delay }}"

    - name: Stop with an error (the pipeline must turn red)
      ansible.builtin.fail:
        msg: >-
          Deploy of {{ notes_app_image_tag[:12] }} failed.
          {{ 'Rolled back to ' ~ notes_app_previous_tag[:12] if notes_app_previous_tag is match('^[0-9a-f]{40}$')
             else 'No previous version to roll back to (first deploy).' }}

- name: Remove old images (keep the current one and the previous one)
  ansible.builtin.command:
    cmd: docker image prune -a -f --filter "until=168h"
  changed_when: false
```

| Task | Why |
|---|---|
| assert image tag | must be 40 hex characters; stops typos and empty values |
| read settings | one `query` for 7 SSM parameters; `zip` + `dict` turns the two lists into `{db_host: ..., db_port: ...}`. `no_log` hides the password |
| remember previous tag | SSM `image_tag` = the last version that deployed successfully |
| RDS bundle | AWS's public certificate list for RDS |
| `.env` | 0600 root; `no_log` |
| **block** | the deploy steps; any failure jumps to **rescue** |
| pull | download the new image first (the old one keeps running meanwhile) |
| migrations | `docker compose run --rm app npm run migrate` = a temporary container from the new image runs `knex migrate:latest`; `changed` only if it really migrated |
| `up -d` | replaces the container with the new image (a few seconds of downtime; zero-downtime is advanced level) |
| wait `/ready` | up to 20 × 3 s = 60 s |
| smoke tests (`delegate_to: localhost`) | run **on the Jenkins server**, through the internet → Caddy → app; `/health` must show the **new** SHA |
| **rescue** | print where it failed (`ansible_failed_task.name`); if a valid previous version exists, write compose.yml with it, start it, wait until ready; then `fail` so the build is red |
| prune | remove unused images older than 7 days |

---

## 7.9 Commands

### Branch, Terraform, tools

```bash
cd ~/Documents/"nodejs cicd"
git checkout main && git pull
git checkout -b feature/phase-7-pipeline
chmod -R u=rwX,go=rX .
cd infra/terraform/envs/prod
terraform apply                         # Plan: 2 to add

source ~/.venvs/ansible/bin/activate
cd ~/Documents/"nodejs cicd"/infra/ansible
ansible-playbook playbooks/site.yml --limit jenkins
ansible jenkins -a "trivy --version"
ansible jenkins -a "/usr/local/bin/aws --version"
ansible jenkins -a "/opt/ansible/bin/ansible --version"
ansible jenkins -b -a "cat /var/lib/jenkins/.docker/config.json"
```

### Release

```bash
cd ~/Documents/"nodejs cicd"
git add Jenkinsfile infra docs
git commit -m "Phase 7: build, Trivy scan, push to ECR, Ansible deploy with smoke test and rollback"
git push -u origin feature/phase-7-pipeline
gh pr create --base main --head feature/phase-7-pipeline --fill
sleep 60
gh pr checks 9 --watch
gh pr merge 9 --merge --delete-branch
git checkout main && git pull
```

### Wait for the `main` build from the terminal

```bash
JPASS=$(aws ssm get-parameter --name /notes-devops/prod/jenkins_admin_password --with-decryption --query Parameter.Value --output text)
URL=https://jenkins.15-206-136-1.sslip.io/job/notes-devops/job/main/lastBuild
while curl -s -u "admin:$JPASS" "$URL/api/json?tree=building" | grep -q '"building":true'; do echo "building..."; sleep 20; done
curl -s -u "admin:$JPASS" "$URL/api/json?tree=number,result"; echo
curl -s -u "admin:$JPASS" "$URL/consoleText" | tail -40
unset JPASS
```

| Part | Meaning |
|---|---|
| `curl -u admin:$JPASS` | log in to Jenkins' API with the admin password |
| `.../lastBuild/api/json?tree=building` | Jenkins' JSON API: only the field `building` |
| `while ... grep -q '"building":true'; do ...; done` | repeat every 20 s while the build is running |
| `/consoleText` | the build log as plain text |

### Check the release

```bash
git rev-parse HEAD
curl -s https://notes.16-4-130-144.sslip.io/health; echo
aws ssm get-parameter --name /notes-devops/prod/image_tag --query Parameter.Value --output text
aws ecr list-images --repository-name notes-app --query "imageIds[].imageTag"
```

### Rollback test

```bash
git checkout main && git pull
git checkout -b test/rollback
sed -i '' 's#CMD \["node", "src/server.js"\]#CMD ["node", "src/does-not-exist.js"]#' app/Dockerfile
git commit -am "Test: broken release to check automatic rollback"
git push -u origin test/rollback
gh pr create --base main --head test/rollback --fill
sleep 90
gh pr checks test/rollback --watch
gh pr merge test/rollback --merge --delete-branch
```

Undo it (a new PR that reverts the merge):

```bash
git checkout main && git pull
git checkout -b fix/revert-broken-release
git revert -m 1 HEAD --no-edit
git push -u origin fix/revert-broken-release
gh pr create --base main --head fix/revert-broken-release --fill
sleep 90
gh pr checks fix/revert-broken-release --watch
gh pr merge fix/revert-broken-release --merge --delete-branch
git checkout main && git pull
```

| Command | Meaning |
|---|---|
| `git revert -m 1 HEAD` | make a **new** commit that undoes the last commit. `HEAD` is a merge commit (it has 2 parents); `-m 1` = "keep the `main` side (parent 1), undo what the PR brought in". History is not rewritten, so it works with protected `main` |

---

## 7.10 Results

### First release (PR #9)

| Check | Value |
|---|---|
| Jenkins `main` build #4 | SUCCESS (all 5 stages) |
| `git rev-parse HEAD` | `e20403203189af52a4df0c3f5dc7d02194faa4e8` |
| `/health` | `{"status":"ok","version":"e20403203189af52a4df0c3f5dc7d02194faa4e8"}` |
| SSM `image_tag` | `e20403203189af52a4df0c3f5dc7d02194faa4e8` |
| ECR images | `["e20403203189af52a4df0c3f5dc7d02194faa4e8"]` |
| Browser | Notes app at `https://notes.16-4-130-144.sslip.io` |

### Rollback test (broken `CMD`)

```text
TASK [notes_app : Start the new version]
TASK [notes_app : Wait until the app is ready (database connected)]      ← 80 s of retries
TASK [notes_app : Deploy failed]
    msg: 'Deploy of fdbea47ee226 failed at: Wait until the app is ready (database connected)'
TASK [notes_app : Write compose.yml with the previous image]
TASK [notes_app : Start the previous version]
TASK [notes_app : Wait until the previous version is ready]
TASK [notes_app : Stop with an error (the pipeline must turn red)]
    msg: Deploy of fdbea47ee226 failed. Rolled back to e20403203189
```

| Check | Result |
|---|---|
| Jenkins `main` | FAILURE in **Deploy** (as intended) |
| `/health` afterwards | `"version":"e20403203189af52a4df0c3f5dc7d02194faa4e8"`: the site stayed on the good version |
| SSM `image_tag` | unchanged (`e20403203189...`): the `put-parameter` step never ran |

**Lesson:** tests passed (they don't start the production container), so only the deploy checks could catch this. That's why smoke tests and automatic rollback exist.

---

## 7.11 Problems and fixes

### `parameter not found` for `smtp_password`; `alert_email` = `YOUR_EMAIL@gmail.com`
- **Cause:** email was planned; `terraform.tfvars` still had the example address.
- **Decision:** email turned off (P7-21). Jenkins no longer reads `smtp_password` or `alert_email`; the SSM `alert_email` parameter stays but is unused.

### `error: src refspec feature/phase-7-pipeline does not match any`
- **Cause:** the branch was never created (`git checkout -b` skipped), so the commit landed on local `main`. Pushing `main` directly would be refused by the ruleset anyway.
- **Fix:** `git branch feature/phase-7-pipeline` (keep the commit on a new branch) → `git reset --hard origin/main` (local main = GitHub again) → `git checkout feature/phase-7-pipeline` → push → PR.
- **Habit:** `git branch --show-current` before committing.

### `no checks reported` right after `gh pr create`
- **Cause:** `gh pr checks` ran before Jenkins had even started; with no check yet, `--watch` has nothing to wait for and stops.
- **Fix:** `sleep 60` (or 90) before `gh pr checks --watch`.

### Checks run too early showed `none` / `[]`
- **Cause:** the `main` build was still running.
- **Fix:** the `while ... building ...` loop waits for the result.
