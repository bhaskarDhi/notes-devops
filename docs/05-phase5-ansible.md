# Phase 5: Ansible (dynamic inventory, `common`, `docker`, `caddy`)

**Goal:** one command configures all 3 servers: updates, swap, Docker, and HTTPS with Caddy on the app and Jenkins servers.

**Done when:** `ansible-playbook playbooks/site.yml` finishes with `failed=0`, a second run shows `changed=0`, and both sslip.io addresses answer over HTTPS (with `502` for now).

> Ansible basics (inventory, playbooks, modules, roles, handlers, templates, variables) are explained from zero in **`notes-ansible.md`**. This chapter is the project journal: decisions, files, commands, results and problems.

---

## 5.1 What this phase does

```text
Mac (control node)
 │  ansible-playbook playbooks/site.yml
 │
 ├─ AWS API ──► "running servers with Project=notes-devops, Environment=prod" → app, jenkins, monitoring
 │
 └─ SSH ──► Jenkins (bastion, public IP) ──► each server's private IP
             │
             ├─ all 3:          common (updates, base tools, auto security updates, 2 GB swap)
             │                  docker (official Docker Engine + compose, log limits, ubuntu in docker group)
             └─ app + jenkins:  caddy  (HTTPS for notes.<ip>.sslip.io / jenkins.<ip>.sslip.io)
```

---

## 5.2 Decisions in this phase

| # | Decision | Why |
|---|---|---|
| P5-1 | Run Ansible from the **Mac** now; from the **Jenkins server** later (deploys) | the Jenkins server doesn't exist as a CI server yet (chicken and egg). The same files work in both places |
| P5-2 | Ansible in a Python **virtual environment** (`~/.venvs/ansible`) | separate from conda and the system Python; easy to delete or upgrade |
| P5-3 | Full `ansible` package + `boto3`; collections pinned in `requirements.yml` | the package includes `amazon.aws` and `ansible.posix`; the file makes Jenkins install the same ones |
| P5-4 | **Dynamic inventory** `amazon.aws.aws_ec2`, groups from the `Role` tag (`ec2_tags.Role`) | IPs change after each destroy/apply; tags don't |
| P5-5 | Hosts named by the `Name` tag | readable output (`notes-devops-prod-app`) instead of IPs |
| P5-6 | Connect to **private IPs through the bastion** (`ProxyCommand`), switchable with `use_bastion` | only the Jenkins server has public SSH; inside the VPC (Jenkins) set `use_bastion=false` |
| P5-7 | `StrictHostKeyChecking=accept-new` | new servers each session are trusted automatically the first time; a **changed** key still stops us |
| P5-8 | Three small roles: `common`, `docker`, `caddy` | one job per role; reusable; Phase 6–8 add `jenkins`, `app`, `monitoring` |
| P5-9 | Variables in a role start with the role name | `ansible-lint` rule; avoids name clashes |
| P5-10 | 2 GB **swap** on every server | t3.small has 2 GB RAM; swap prevents the OOM killer from stopping services during peaks |
| P5-11 | No automatic reboot, no ufw, timezone UTC | rebooting the bastion mid-run cuts other connections; security groups already filter; UTC is the server standard |
| P5-12 | Docker from Docker's **official repository** (`deb822_repository`) | newest Engine + `buildx` + `compose` plugins; signed packages |
| P5-13 | Docker log limit 3 × 10 MB per container | default logs grow forever and can fill the disk |
| P5-14 | Caddy from Caddy's **official repository** | recommended version |
| P5-15 | Caddyfile written with `validate:` | a broken Caddyfile is never installed |
| P5-16 | Caddy **reload** (not restart) in the handler | no dropped connections |
| P5-17 | No Caddy on monitoring | it has no public web ports; Grafana is reached through an SSH tunnel |
| P5-18 | `ansible-lint` (production profile) must pass | catches mistakes and bad habits before they reach servers |

---

## 5.3 Folder layout

```text
infra/ansible/
├── ansible.cfg
├── requirements.yml
├── inventory/
│   ├── aws_ec2.yml               dynamic inventory
│   └── group_vars/
│       ├── all.yml               user, bastion, sslip.io domain
│       ├── app.yml               caddy_site / caddy_upstream for the app
│       └── jenkins.yml           caddy_site / caddy_upstream for Jenkins
├── playbooks/
│   ├── ping.yml
│   └── site.yml
└── roles/
    ├── common/   defaults · tasks · handlers
    ├── docker/   defaults · tasks · handlers · templates/daemon.json.j2
    └── caddy/    defaults · tasks · handlers · templates/Caddyfile.j2
```

---

## 5.4 The files

<sub>File: `infra/ansible/ansible.cfg`</sub>

```ini
[defaults]
inventory = inventory/aws_ec2.yml
roles_path = roles
remote_user = ubuntu
interpreter_python = auto_silent
callback_result_format = yaml
forks = 10

[inventory]
enable_plugins = amazon.aws.aws_ec2

[ssh_connection]
pipelining = True
```

<sub>File: `infra/ansible/requirements.yml`</sub>

```yaml
collections:
  - name: amazon.aws
    version: ">=11.2.0"
  - name: ansible.posix
    version: ">=2.0.0"
```

<sub>File: `infra/ansible/inventory/aws_ec2.yml`</sub>

```yaml
plugin: amazon.aws.aws_ec2
regions:
  - ap-south-1
filters:
  instance-state-name: running
  tag:Project: notes-devops
  tag:Environment: prod
hostnames:
  - tag:Name
groups:
  app: ec2_tags.Role == 'app'
  jenkins: ec2_tags.Role == 'jenkins'
  monitoring: ec2_tags.Role == 'monitoring'
compose:
  ansible_host: private_ip_address
```

<sub>File: `infra/ansible/inventory/group_vars/all.yml`</sub>

```yaml
ansible_user: ubuntu

use_bastion: true
bastion_ip: "{{ hostvars[groups['jenkins'][0]]['public_ip_address'] }}"
ansible_ssh_common_args: >-
  -o StrictHostKeyChecking=accept-new
  {% if use_bastion | bool %}-o ProxyCommand="ssh -W %h:%p -q -o StrictHostKeyChecking=accept-new ubuntu@{{ bastion_ip }}"{% endif %}

sslip_domain: "{{ public_ip_address | replace('.', '-') }}.sslip.io"
```

<sub>File: `infra/ansible/inventory/group_vars/app.yml`</sub>

```yaml
caddy_site: "notes.{{ sslip_domain }}"
caddy_upstream: "127.0.0.1:3000"
```

<sub>File: `infra/ansible/inventory/group_vars/jenkins.yml`</sub>

```yaml
caddy_site: "jenkins.{{ sslip_domain }}"
caddy_upstream: "127.0.0.1:8080"
```

<sub>File: `infra/ansible/playbooks/site.yml`</sub>

```yaml
- name: Base setup (all servers)
  hosts: all
  become: true
  roles:
    - common
    - docker

- name: HTTPS reverse proxy (app and Jenkins)
  hosts: app:jenkins
  become: true
  roles:
    - caddy
```

<sub>File: `infra/ansible/playbooks/ping.yml`</sub>

```yaml
- name: Check that every server answers
  hosts: all
  gather_facts: false
  tasks:
    - name: Ping
      ansible.builtin.ping:
```

<sub>File: `infra/ansible/roles/common/defaults/main.yml`</sub>

```yaml
common_packages:
  - ca-certificates
  - curl
  - gnupg
  - unzip
  - jq
  - htop
  - unattended-upgrades
  - python3-debian

common_swap_size_mb: 2048
common_swap_file: /swapfile
```

<sub>File: `infra/ansible/roles/common/tasks/main.yml`</sub>

```yaml
- name: Update apt cache and upgrade packages
  ansible.builtin.apt:
    update_cache: true
    cache_valid_time: 3600
    upgrade: safe

- name: Install base packages
  ansible.builtin.apt:
    name: "{{ common_packages }}"
    state: present

- name: Enable automatic security updates
  ansible.builtin.copy:
    dest: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
    owner: root
    group: root
    mode: "0644"

- name: Create swap file
  ansible.builtin.command:
    cmd: "fallocate -l {{ common_swap_size_mb }}M {{ common_swap_file }}"
    creates: "{{ common_swap_file }}"
  when: common_swap_size_mb | int > 0
  notify: Enable swap

- name: Protect swap file
  ansible.builtin.file:
    path: "{{ common_swap_file }}"
    owner: root
    group: root
    mode: "0600"
  when: common_swap_size_mb | int > 0

- name: Enable swap at boot
  ansible.posix.mount:
    src: "{{ common_swap_file }}"
    path: none
    fstype: swap
    opts: sw
    state: present
  when: common_swap_size_mb | int > 0

- name: Use swap only when RAM is almost full
  ansible.posix.sysctl:
    name: vm.swappiness
    value: "10"
    state: present
    sysctl_file: /etc/sysctl.d/99-swap.conf
```

<sub>File: `infra/ansible/roles/common/handlers/main.yml`</sub>

```yaml
- name: Enable swap
  ansible.builtin.shell:
    cmd: "mkswap {{ common_swap_file }} && swapon {{ common_swap_file }}"
  changed_when: true
```

<sub>File: `infra/ansible/roles/docker/defaults/main.yml`</sub>

```yaml
docker_users:
  - ubuntu

docker_log_max_size: 10m
docker_log_max_file: 3
```

<sub>File: `infra/ansible/roles/docker/tasks/main.yml`</sub>

```yaml
- name: Remove old or conflicting Docker packages
  ansible.builtin.apt:
    name:
      - docker.io
      - docker-doc
      - docker-compose
      - docker-compose-v2
      - podman-docker
      - containerd
      - runc
    state: absent

- name: Add the official Docker repository
  ansible.builtin.deb822_repository:
    name: docker
    types: deb
    uris: https://download.docker.com/linux/ubuntu
    suites: "{{ ansible_facts['distribution_release'] }}"
    components: stable
    architectures: "{{ 'arm64' if ansible_facts['architecture'] == 'aarch64' else 'amd64' }}"
    signed_by: https://download.docker.com/linux/ubuntu/gpg

- name: Install Docker Engine and plugins
  ansible.builtin.apt:
    name:
      - docker-ce
      - docker-ce-cli
      - containerd.io
      - docker-buildx-plugin
      - docker-compose-plugin
    state: present
    update_cache: true

- name: Limit container log size
  ansible.builtin.template:
    src: daemon.json.j2
    dest: /etc/docker/daemon.json
    owner: root
    group: root
    mode: "0644"
  notify: Restart docker

- name: Start Docker now and at boot
  ansible.builtin.systemd_service:
    name: docker
    state: started
    enabled: true

- name: Allow users to run docker without sudo
  ansible.builtin.user:
    name: "{{ item }}"
    groups: docker
    append: true
  loop: "{{ docker_users }}"

- name: Reconnect so the new group is active
  ansible.builtin.meta: reset_connection
```

<sub>File: `infra/ansible/roles/docker/templates/daemon.json.j2`</sub>

```jinja
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "{{ docker_log_max_size }}",
    "max-file": "{{ docker_log_max_file }}"
  }
}
```

<sub>File: `infra/ansible/roles/docker/handlers/main.yml`</sub>

```yaml
- name: Restart docker
  ansible.builtin.systemd_service:
    name: docker
    state: restarted
```

<sub>File: `infra/ansible/roles/caddy/defaults/main.yml`</sub>

```yaml
caddy_site: ""
caddy_upstream: "127.0.0.1:3000"
```

<sub>File: `infra/ansible/roles/caddy/tasks/main.yml`</sub>

```yaml
- name: Check that a site name is set
  ansible.builtin.assert:
    that: caddy_site | length > 0
    fail_msg: "caddy_site is empty for {{ inventory_hostname }}"

- name: Add the official Caddy repository
  ansible.builtin.deb822_repository:
    name: caddy
    types: deb
    uris: https://dl.cloudsmith.io/public/caddy/stable/deb/debian
    suites: any-version
    components: main
    signed_by: https://dl.cloudsmith.io/public/caddy/stable/gpg.key

- name: Install Caddy
  ansible.builtin.apt:
    name: caddy
    state: present
    update_cache: true

- name: Write the Caddyfile
  ansible.builtin.template:
    src: Caddyfile.j2
    dest: /etc/caddy/Caddyfile
    owner: root
    group: caddy
    mode: "0644"
    validate: caddy validate --adapter caddyfile --config %s
  notify: Reload caddy

- name: Start Caddy now and at boot
  ansible.builtin.systemd_service:
    name: caddy
    state: started
    enabled: true
```

<sub>File: `infra/ansible/roles/caddy/templates/Caddyfile.j2`</sub>

```jinja
# Managed by Ansible - changes here are overwritten

{{ caddy_site }} {
	encode zstd gzip
	reverse_proxy {{ caddy_upstream }}
}
```

<sub>File: `infra/ansible/roles/caddy/handlers/main.yml`</sub>

```yaml
- name: Reload caddy
  ansible.builtin.systemd_service:
    name: caddy
    state: reloaded
```

Line-by-line explanations of every file are in `notes-ansible.md` (sections C5, C16, C17 and C18).

---

## 5.5 Commands

One-time setup on the Mac:

```bash
python3 -m venv ~/.venvs/ansible
source ~/.venvs/ansible/bin/activate
pip install --upgrade pip
pip install ansible boto3
ansible --version
```

Each session:

```bash
source ~/.venvs/ansible/bin/activate
cd ~/Documents/"nodejs cicd"/infra/ansible
chmod -R u=rwX,go=rX .
ansible-galaxy collection install -r requirements.yml
ansible-inventory --graph
ansible-playbook playbooks/ping.yml
ansible-playbook playbooks/site.yml
ansible-playbook playbooks/site.yml          # second run → changed=0
```

Checks:

```bash
ansible all -a "docker --version"
ansible all -a "swapon --show"
ansible all -m debug -a "var=caddy_site"
curl -s -o /dev/null -w "%{http_code}\n" https://notes.16-4-130-144.sslip.io
curl -s -o /dev/null -w "%{http_code}\n" https://jenkins.15-206-136-1.sslip.io
ansible app:jenkins -b -m shell -a "journalctl -u caddy --no-pager --since '-5 min' | tail -2"
```

GitHub:

```bash
cd ~/Documents/"nodejs cicd"
git add infra/ansible docs
git status --short
git commit -m "Phase 5: Ansible dynamic inventory and roles common, docker, caddy"
git push -u origin feature/phase-5-ansible
gh pr create --base main --head feature/phase-5-ansible --fill
gh pr merge feature/phase-5-ansible --merge --delete-branch
git checkout main
git pull
```

---

## 5.6 Results

| Check | Result |
|---|---|
| `ansible-inventory --graph` | `@app`, `@jenkins`, `@monitoring`, each with its `notes-devops-prod-…` server |
| `ping.yml` | 3 × `ok` |
| `site.yml` second run | `changed=0 unreachable=0 failed=0` on all 3 (app/jenkins `ok=20`, monitoring `ok=14`) |
| `docker --version` | `Docker version 29.9.2` on all 3 |
| `swapon --show` | `/swapfile file 2G` on all 3 |
| HTTPS | TLS 1.3 + HTTP/2 to `notes.16-4-130-144.sslip.io` and `jenkins.15-206-136-1.sslip.io`; status `502` (nothing behind Caddy yet) |
| `ansible-lint playbooks roles` | `Passed: 0 failure(s), 0 warning(s)` (production profile) |

Caddy's log shows `dial tcp 127.0.0.1:3000: connect: connection refused` → `502`. That's correct: the app arrives in Phase 7 and Jenkins in Phase 6.

**Interesting:** a few minutes after the certificate was issued, Caddy's log showed a **bot** (`CT-WP-Scanner`) asking for `/xmlrpc.php` (a WordPress file) on the Jenkins address. Every new HTTPS certificate is published in public **Certificate Transparency** logs, and bots watch these logs to scan new sites. Any server on the internet gets scanned within minutes. That is why Jenkins must have a login and strong settings (Phase 6), and why app/monitoring ports are closed to the internet.

---

## 5.7 Problems and fixes

### `[DEPRECATION WARNING]: The 'tags' host variable is deprecated. Use 'ec2_tags' instead.`
- **Cause:** amazon.aws (11.2+) renamed the tag map to `ec2_tags`, because `tags` is a reserved word in Ansible.
- **Fix:** the inventory uses `ec2_tags.Role`, and `requirements.yml` asks for `amazon.aws >= 11.2.0`.
- **Note:** the plugin still prints the warning on every run (it keeps the old `tags` variable for old playbooks). It is harmless and goes away when amazon.aws removes `tags` (after 2026-12-01).

### `head: Unknown option: 1` (on the Mac)
- **Cause:** the Mac's file system ignores upper/lower case, and conda's `HEAD` program (a Perl HTTP tool) comes before `/usr/bin/head` in the PATH.
- **Fix:** let curl print only the status code: `curl -s -o /dev/null -w "%{http_code}\n" URL`.

### `curl` returned `000`; Caddy: `rejectedIdentifier ... Cannot issue for "notes.ec2-16-4-130-144.ap-south-1.compute.amazonaws.com"`
- **Cause:** our variable `public_dns_name` had the same name as a variable the aws_ec2 plugin already sets for every server (the AWS DNS name). Inventory host variables beat `group_vars`, so Caddy got the AWS name, and Let's Encrypt refuses `amazonaws.com` names. Without a certificate, the HTTPS connection fails, and curl shows `000`.
- **How we found it:** `journalctl -u caddy | grep '"error"'` showed the wrong name.
- **Fix:** rename it to `sslip_domain`; `site.yml` again (`changed=2`: new Caddyfile + reload); certificate within a minute.
- **Lesson:** use clear, project-specific variable names, and check `ansible-inventory --host NAME` for names that already exist.
