# Notes: Ansible (from zero to this project)

**Project:** notes-devops · **Author:** Bhaskar Bora · **Date:** 25 October 2026

> This guide assumes you only know basic Linux and Ubuntu. It explains Ansible from the very beginning, then goes through every file we use in this project, line by line, and says why each one is written the way it is.

---

## C1. What Ansible is

**Ansible** is a tool that **configures servers** for you. You write down how a server should look ("Docker installed", "this file exists with this content", "Caddy running"), and Ansible connects to the servers over **SSH** and makes it so.

### The problem it solves

In the beginner project we set up the server by hand:

```bash
ssh ubuntu@SERVER
sudo apt update
sudo apt install -y docker.io
sudo usermod -aG docker ubuntu
sudo nano /etc/...        # edit config files by hand
```

| Doing it by hand (or with a bash script) | With Ansible |
|---|---|
| You must remember every step | Every step is written in a file (in Git) |
| 3 servers = do it 3 times | One command does all servers at the same time |
| Run a script twice and it can break ("already exists" errors) or add things twice | Run it twice: the second run changes **nothing** (idempotent) |
| You can't see what *would* change | `--check --diff` shows what would change before doing it |
| A new server after `terraform destroy` = start again by hand | A new server = run the same command again |

### Terraform vs Ansible: who does what?

```text
 Terraform                                   Ansible
 ─────────                                   ───────
 CREATES the things                          CONFIGURES what is inside the servers
 • VPC, subnets, firewalls                   • packages (Docker, Caddy, ...)
 • EC2 servers, RDS, IAM, SSM                • config files (Caddyfile, daemon.json)
 • talks to the AWS API                      • services (start, restart, enable)
                                             • talks to the servers over SSH
```

> **Analogy:** Terraform builds the house (walls, doors, electricity). Ansible furnishes it (furniture, appliances, settings). You can rebuild the house and furnish it again exactly the same way.

### Three words you will hear a lot

| Word | Simple meaning |
|---|---|
| **Agentless** | nothing has to be installed on the servers first. Ansible only needs SSH and Python, and Ubuntu already has both. (Chef and Puppet need an "agent" program on every server.) |
| **Idempotent** | running the same thing once or ten times gives the same result. Ansible checks first ("is Docker already installed?") and acts only when needed. |
| **Declarative** | you describe the **result** you want (`state: present`), not the commands to get there |

---

## C2. How Ansible works

```text
     CONTROL NODE (where you run Ansible)                MANAGED NODES (the servers)
     ────────────────────────────────────                ───────────────────────────
     your Mac (now), the Jenkins server (later)

     ansible-playbook site.yml
        │ 1. read the inventory  → which servers?
        │ 2. read the playbook   → what to do?
        │ 3. for each task:
        │      connect with SSH ──────────────────────────►  server
        │      send a small Python program (the "module") ►  runs it
        │      get the result back (JSON) ◄────────────────  ok / changed / failed
        │      delete the program on the server
        ▼ 4. print a summary (PLAY RECAP)
```

| Term | Meaning |
|---|---|
| **Control node** | the computer where Ansible is installed and where you type the command |
| **Managed node** (host) | a server Ansible configures |
| **Inventory** | the list of servers, put into groups |
| **Module** | a small built-in program that does one job (install a package, copy a file, start a service) |
| **Task** | one call to a module, with a name |
| **Play** | "on these servers, run these tasks" |
| **Playbook** | a YAML file with one or more plays |
| **Role** | a folder that packs related tasks, files, templates and default settings together (e.g. `docker`) |
| **Handler** | a task that runs only when another task changed something (e.g. "restart Docker") |
| **Facts** | information Ansible collects about each server (OS version, IP, CPU type, ...) |
| **Collection** | a downloadable package of extra modules and plugins (e.g. `amazon.aws`) |

### In this project

```text
 Mac ──SSH──► Jenkins server (bastion, public IP) ──SSH──► app server        (private IP 10.20.1.x)
                     │                              └──► monitoring server (private IP 10.20.2.x)
                     └── also configured itself (through its own private IP)

 Mac ──AWS API (boto3)──► "which servers have tag Project=notes-devops?"  (dynamic inventory)
```

Only the Jenkins server accepts SSH from the internet (only from your IP). Ansible reaches the other servers **through** it, exactly like `ssh -J` in Phase 4.

---

## C3. Installing Ansible on the Mac

```bash
python3 -m venv ~/.venvs/ansible
source ~/.venvs/ansible/bin/activate
pip install --upgrade pip
pip install ansible boto3
ansible --version
```

| Command | Why |
|---|---|
| `python3 -m venv ~/.venvs/ansible` | makes a **virtual environment**: a private folder with its own Python packages. Ansible's packages don't mix with conda or other projects, and you can delete the folder to remove everything. |
| `source .../activate` | "use this environment in this terminal". Your prompt shows `(ansible)`. You must do this in **every new terminal**. |
| `pip install ansible` | `ansible` = `ansible-core` (the engine and the basic `ansible.builtin` modules) **plus** many collections, including `amazon.aws` and `ansible.posix` |
| `boto3` | the AWS library for Python. The dynamic inventory uses it to ask AWS for the server list. |

`ansible --version` shows `ansible [core 2.2x.x]`, the Python it uses, and which `ansible.cfg` it found.

### Collections and `requirements.yml`

<sub>File: `infra/ansible/requirements.yml`</sub>

```yaml
collections:
  - name: amazon.aws
    version: ">=11.2.0"
  - name: ansible.posix
    version: ">=2.0.0"
```

```bash
ansible-galaxy collection install -r requirements.yml
```

This writes down exactly which collections the project needs. The Jenkins server (Phase 6) installs from the same file, so both control nodes have the same modules.

| Collection | What we use from it |
|---|---|
| `ansible.builtin` | comes with ansible-core: `apt`, `copy`, `template`, `file`, `command`, `shell`, `systemd_service`, `user`, `deb822_repository`, `assert`, `ping`, `debug`, `meta` |
| `amazon.aws` | the `aws_ec2` inventory plugin (find servers by tag) |
| `ansible.posix` | `mount` (swap in `/etc/fstab`) and `sysctl` (kernel settings) |

**FQCN** (Fully Qualified Collection Name) means writing the full name of a module, such as `ansible.builtin.apt` instead of just `apt`. It is clearer, avoids name clashes, and `ansible-lint` requires it.

---

## C4. YAML in 5 minutes

All Ansible files (except `ansible.cfg` and templates) are **YAML**.

```yaml
# a comment
name: notes-app              # key: value   (a "dictionary" / map)
port: 3000                   # number
enabled: true                # boolean: true / false
packages:                    # a list: each item starts with "- "
  - curl
  - jq
server:                      # a map inside a map (indent with 2 SPACES, never tabs)
  role: app
  ip: 10.20.1.64
short_list: [a, b, c]        # a list on one line
short_map: { http: 80, https: 443 }
```

| Rule | Example |
|---|---|
| Indentation means "belongs to" | `role:` is inside `server:` |
| Use **spaces**, never tabs | 2 spaces per level |
| `- ` starts a list item | `- curl` |
| Quote strings that start with `{{` or contain `: ` | `name: "{{ item }}"` |
| Quote things that look like numbers but must stay text | `mode: "0644"` (otherwise YAML reads it as the number 644) |
| `\|` keeps line breaks (multi-line text) | used for file contents |
| `>-` folds lines into one line with spaces | used for the long SSH options |

```yaml
content: |
  line one
  line two          # → "line one\nline two\n"

args: >-
  -o A
  -o B              # → "-o A -o B"
```

A YAML file may start with `---`; it is optional.

---

## C5. Inventory: which servers?

### A static inventory (the simple way, for understanding)

```ini
[app]
10.20.1.64

[monitoring]
10.20.2.146

[jenkins]
15.206.136.1
```

- `[app]` is a **group**. A server can be in many groups.
- `all` is a built-in group containing every server.
- **Problem:** IP addresses change after every `terraform destroy` + `apply`, so you would have to edit this file every session.

### Dynamic inventory (what we use)

Instead of a list, the inventory is a **plugin** that asks AWS every time: *"which servers are running with these tags?"*

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

| Line | Meaning |
|---|---|
| `plugin: amazon.aws.aws_ec2` | use the EC2 plugin. The file name **must** end in `aws_ec2.yml`, or Ansible won't use the plugin. |
| `regions` | only look in Mumbai |
| `filters` | only `running` servers with tags `Project=notes-devops` and `Environment=prod` (Terraform's `default_tags` set these) |
| `hostnames: [tag:Name]` | call each server by its `Name` tag (`notes-devops-prod-app`) instead of an IP |
| `groups:` | put a server in group `app` if its `Role` tag is `app`, and so on (the `Role` tag comes from the Terraform `server` module). `ec2_tags` = all the server's tags as a map (`ec2_tags.Role`, `ec2_tags.Name`) |
| `compose: ansible_host: private_ip_address` | connect to the **private** IP (through the bastion) |

The plugin gives every server many variables taken from AWS: `public_ip_address`, `private_ip_address`, `ec2_tags`, `instance_type`, `placement`, ...

> **Why `ec2_tags` and not `tags`?** `tags` is a reserved word in Ansible (it is used to run only some tasks, `--tags`). The plugin used to call the tag map `tags`. Since amazon.aws 11.2 it is called `ec2_tags`, and `tags` will be removed after 2026-12-01. That's why `requirements.yml` asks for `amazon.aws >= 11.2.0`. We use `public_ip_address` to build the sslip.io names.

It uses **your AWS credentials** (`~/.aws/credentials`, user `terraform-cli`) through `boto3`. Later, on the Jenkins server, it uses the server's **IAM role** (Phase 4 allowed `ec2:DescribeInstances`), so no keys are needed there.

```bash
ansible-inventory --graph          # groups and servers as a tree
ansible-inventory --list           # everything, with all variables (long JSON)
ansible-inventory --host notes-devops-prod-app   # the variables of one server
```

Expected `--graph`:

```text
@all:
  |--@ungrouped:
  |--@app:
  |  |--notes-devops-prod-app
  |--@jenkins:
  |  |--notes-devops-prod-jenkins
  |--@monitoring:
  |  |--notes-devops-prod-monitoring
```

---

## C6. Variables

A variable is a named value, used as `{{ name }}`.

### Where variables come from (the ones we use)

| Place | Example | Used for |
|---|---|---|
| Inventory plugin (from AWS) | `public_ip_address`, `tags` | facts about the server from AWS |
| `inventory/group_vars/all.yml` | `ansible_user`, `bastion_ip` | every server |
| `inventory/group_vars/app.yml` | `caddy_site` | only servers in group `app` |
| `roles/<role>/defaults/main.yml` | `common_swap_size_mb: 2048` | a role's default settings, easy to override |
| Facts (collected at the start of a play) | `ansible_facts['distribution_release']` → `noble` | the server's OS, CPU and so on |
| Command line `-e` | `-e use_bastion=false` | one-off overrides (strongest of all) |

### Who wins when the same variable is set twice? (simplified)

```text
weakest  role defaults  <  group_vars/all  <  group_vars/<group>  <  host vars (inventory)  <  -e on the command line  strongest
```

That's why roles put their settings in `defaults/`: anything else can override them.

### Jinja2: the `{{ }}` language

Ansible uses **Jinja2** to fill in variables and do small calculations.

| Expression | Result / meaning |
|---|---|
| `{{ public_ip_address }}` | `16.4.130.144` |
| `{{ public_ip_address \| replace('.', '-') }}` | `16-4-130-144` (a **filter**: changes a value) |
| `{{ caddy_site \| length > 0 }}` | true if the text is not empty |
| `{{ use_bastion \| bool }}` | turns `"true"` / `"false"` text into a real boolean |
| `{{ x \| default('-') }}` | `-` if `x` is not set |
| `{{ 'a' if cond else 'b' }}` | inline if |
| `{% if cond %} ... {% endif %}` | an if block (`{% %}` = logic, `{{ }}` = output) |
| `{{ groups['jenkins'][0] }}` | first server in group `jenkins` (**magic variable** `groups`) |
| `{{ hostvars['NAME']['public_ip_address'] }}` | a variable of **another** server (**magic variable** `hostvars`) |
| `{{ inventory_hostname }}` | the name of the current server |

---

## C7. Ad-hoc commands: one quick task

Run **one module** on servers without writing a playbook. Good for checks.

```bash
ansible all -m ping                       # can Ansible connect + run Python? → "pong"
ansible all -a "uptime"                   # -a = a shell command (module "command")
ansible app -a "docker ps"
ansible all -a "df -h /"
ansible all -b -a "systemctl status caddy --no-pager"   # -b = become root (sudo)
ansible monitoring -m setup -a "filter=ansible_distribution*"   # show some facts
```

| Part | Meaning |
|---|---|
| `all` / `app` / `jenkins` | which servers (a group or server name). `app:jenkins` = both groups |
| `-m MODULE` | which module (default `command`) |
| `-a "..."` | the arguments |
| `-b` | **become**: run as root with sudo |

`ping` is **not** a network ping: it logs in with SSH and runs a tiny Python program that answers `pong`.

---

## C8. Playbooks

A **playbook** is a YAML file with a list of **plays**. Each play says *which servers* and *which tasks or roles*.

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

| Key | Meaning |
|---|---|
| `- name:` | a description, printed while it runs |
| `hosts: all` | which servers (group names, `all`, `app:jenkins`) |
| `become: true` | run tasks as root (like `sudo`); installing packages needs root |
| `roles:` | run these roles in this order |
| `tasks:` | or list tasks directly (see `ping.yml`) |
| `gather_facts: false` | skip collecting facts (faster when not needed) |

<sub>File: `infra/ansible/playbooks/ping.yml`</sub>

```yaml
- name: Check that every server answers
  hosts: all
  gather_facts: false
  tasks:
    - name: Ping
      ansible.builtin.ping:
```

### Anatomy of a task

```yaml
- name: Install base packages             # what it does (shown in the output)
  ansible.builtin.apt:                    # which module
    name: "{{ common_packages }}"         # module arguments
    state: present
  when: common_packages | length > 0      # (optional) condition
  notify: Some handler                    # (optional) run a handler if changed
```

### Order of execution

1. Gather facts (unless `gather_facts: false`).
2. Run the tasks **in order**, each task on **all servers at the same time** (up to `forks`) before moving to the next task.
3. A server that fails is dropped from the rest of the play; the others continue.
4. At the end of the play, run any **handlers** that were notified.
5. Print the **PLAY RECAP**.

---

## C9. Modules we use

| Module | What it does | Instead of (by hand) |
|---|---|---|
| `apt` | install, remove or upgrade packages; update the apt cache | `apt update`, `apt install`, `apt upgrade` |
| `deb822_repository` | add a software repository + its signing key | `curl ... gpg`, editing `/etc/apt/sources.list.d/` |
| `copy` | create a file with the given content, owner and mode | `echo ... > file`, `chmod`, `chown` |
| `template` | create a file from a Jinja2 template (variables filled in) | editing with `nano` |
| `file` | set permissions/owner, create folders or links | `chmod`, `chown`, `mkdir` |
| `command` | run a command (no shell features like `&&`, `\|`, `>`) | typing a command |
| `shell` | run a command through `/bin/sh` (allows `&&`, pipes) | typing a command |
| `systemd_service` | start, stop, restart, reload or enable a service | `systemctl start/enable/restart` |
| `user` | create users, add them to groups | `usermod -aG docker ubuntu` |
| `mount` (ansible.posix) | manage `/etc/fstab` entries | editing `/etc/fstab` |
| `sysctl` (ansible.posix) | set kernel settings, now and at boot | `sysctl -w` + editing `/etc/sysctl.d/` |
| `assert` | stop with a clear message if a condition is false | — |
| `meta: reset_connection` | close and reopen the SSH connection | logging out and in again |
| `ping`, `debug` | test the connection / print a value | — |

Prefer a **real module** over `command`/`shell`: modules know whether something is already done (idempotent), while `command` runs every time unless you tell it otherwise (see C10).

---

## C10. ok, changed, failed: idempotency in practice

Every task reports one result per server:

| Result | Colour | Meaning |
|---|---|---|
| `ok` | green | already correct, nothing done |
| `changed` | yellow | Ansible changed something |
| `skipping` | cyan | the `when:` condition was false |
| `failed` | red | error; this server stops |
| `unreachable` | red | could not connect with SSH |

**First run:** many `changed`. **Second run:** all `ok`, `changed=0`. That proves the playbook is idempotent.

### Making `command`/`shell` idempotent

`command` can't know whether its job is already done, so it always reports `changed`. Ways to fix this:

```yaml
- name: Create swap file
  ansible.builtin.command:
    cmd: "fallocate -l 2048M /swapfile"
    creates: /swapfile          # skip if this file already exists → "ok"
```

| Option | Meaning |
|---|---|
| `creates: PATH` | skip if `PATH` exists |
| `removes: PATH` | run only if `PATH` exists |
| `changed_when: false` | never report `changed` (for read-only commands) |
| `changed_when: true` | always report `changed` |
| Use it as a **handler** | it runs only when something else changed (that's how we run `mkswap`) |

---

## C11. Handlers: "do this only if something changed"

Example: restart Docker **only** if its config file changed.

```yaml
# tasks/main.yml
- name: Limit container log size
  ansible.builtin.template:
    src: daemon.json.j2
    dest: /etc/docker/daemon.json
  notify: Restart docker              # ← "if I changed, call this handler"

# handlers/main.yml
- name: Restart docker                # ← the name must match exactly
  ansible.builtin.systemd_service:
    name: docker
    state: restarted
```

- If the file was already correct (`ok`), Docker is **not** restarted, so running containers are not interrupted for nothing.
- Handlers run **once at the end of the play**, even if notified by several tasks.

---

## C12. Templates (Jinja2 files)

A **template** is a config file with `{{ variables }}` in it. The `template` module fills them in for each server and writes the result.

<sub>File: `infra/ansible/roles/caddy/templates/Caddyfile.j2`</sub>

```jinja
# Managed by Ansible - changes here are overwritten

{{ caddy_site }} {
	encode zstd gzip
	reverse_proxy {{ caddy_upstream }}
}
```

For the app server, this becomes:

```text
notes.16-4-130-144.sslip.io {
	encode zstd gzip
	reverse_proxy 127.0.0.1:3000
}
```

For the Jenkins server, it becomes `jenkins.15-206-136-1.sslip.io` → `127.0.0.1:8080`. It's **one template with two results**, because each group has different variables.

Template files end with `.j2` and live in the role's `templates/` folder.

---

## C13. Roles: organise by job

A **role** is a folder with a fixed layout. Ansible knows where to look for each part.

```text
roles/docker/
├── tasks/main.yml        the steps (required)
├── handlers/main.yml     handlers (restart docker)
├── defaults/main.yml     default settings (lowest priority, easy to override)
├── templates/            .j2 files for the template module
├── files/                plain files for the copy module          (not used yet)
├── vars/main.yml         fixed settings (high priority)            (not used)
└── meta/main.yml         info, dependencies on other roles         (not used)
```

| Why roles | |
|---|---|
| Reuse | `docker` is used on all 3 servers; Jenkins (Phase 6) adds `docker_users: [ubuntu, jenkins]` |
| Clear | each role does one job: `common`, `docker`, `caddy` (later `jenkins`, `app`, `monitoring`) |
| Short playbooks | `site.yml` just lists roles per group |

**Naming rule** (checked by `ansible-lint`): variables in a role start with the role name (`common_swap_size_mb`, `docker_users`, `caddy_site`), so two roles never use the same variable name by accident.

---

## C14. Conditions and loops

```yaml
- name: Create swap file
  ansible.builtin.command: ...
  when: common_swap_size_mb | int > 0      # run only if the condition is true
```

- `when:` has **no** `{{ }}`: it is already a Jinja2 expression.
- `| int` turns text into a number so the comparison works.

```yaml
- name: Allow users to run docker without sudo
  ansible.builtin.user:
    name: "{{ item }}"                      # item = the current list element
    groups: docker
    append: true
  loop: "{{ docker_users }}"                # repeat for each element: ubuntu, (later) jenkins
```

---

## C15. `become`: running as root

On Ubuntu the `ubuntu` user can use `sudo` without a password (AWS sets this up). `become: true` makes Ansible run each task with sudo.

| Where | Effect |
|---|---|
| `become: true` on a play | every task in it runs as root |
| `become: true` on one task | only that task |
| `-b` on the command line | for ad-hoc commands |

Rule: use root only where needed. Reading `docker ps` as `ubuntu` works without sudo because `ubuntu` is in the `docker` group.

---

## C16. `ansible.cfg`: project settings

Ansible looks for `ansible.cfg` in the **current folder** first. That's why we always run commands from `infra/ansible/`.

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

| Setting | Why |
|---|---|
| `inventory = inventory/aws_ec2.yml` | no need to type `-i ...` every time |
| `roles_path = roles` | where the roles are (the path is relative to this file) |
| `remote_user = ubuntu` | the SSH user on Ubuntu AMIs |
| `interpreter_python = auto_silent` | find Python on the server automatically, without a warning |
| `callback_result_format = yaml` | errors are printed as readable YAML instead of one long JSON line |
| `forks = 10` | work on up to 10 servers at the same time |
| `enable_plugins = amazon.aws.aws_ec2` | only the AWS inventory plugin is allowed (faster, clear errors) |
| `pipelining = True` | fewer SSH round-trips per task, so it runs faster |

Ansible **ignores** `ansible.cfg` in a world-writable folder (for security). That's one reason for `chmod -R u=rwX,go=rX infra/ansible`.

---

## C17. Reaching private servers through the bastion

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

| Line | Meaning |
|---|---|
| `ansible_user: ubuntu` | log in as `ubuntu` |
| `use_bastion: true` | from the Mac we must go through the bastion. Jenkins (inside the VPC) will run with `-e use_bastion=false` |
| `bastion_ip` | the **public** IP of the first server in group `jenkins`, looked up from the inventory (no IP typed anywhere) |
| `ansible_ssh_common_args` | extra options Ansible adds to every `ssh` command |
| `StrictHostKeyChecking=accept-new` | first time: trust and remember the server's key automatically. If a **known** server's key changes, stop (protects against fake servers) |
| `ProxyCommand="ssh -W %h:%p ... ubuntu@BASTION"` | first SSH to the bastion, then let it forward the connection to `%h:%p` (the target's private IP, port 22). Same idea as `ssh -J` |
| `-q` | quiet: don't print the bastion's banner |
| `sslip_domain` | `16-4-130-144.sslip.io`, used by the Caddy site names |

With `use_bastion: true`, the rendered value is:

```text
-o StrictHostKeyChecking=accept-new -o ProxyCommand="ssh -W %h:%p -q -o StrictHostKeyChecking=accept-new ubuntu@15.206.136.1"
```

Your Mac's key (`~/.ssh/id_ed25519`) is used for **both** hops. It never gets copied to the bastion.

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

The monitoring server gets no Caddy: it has no public web ports (Grafana is reached through an SSH tunnel, see the system design).

---

## C18. Our roles, task by task

### Role `common`: basic setup for every server

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

| Task | Why |
|---|---|
| Update cache + `upgrade: safe` | install security fixes on a fresh server. `cache_valid_time: 3600` skips `apt update` if it ran in the last hour (faster second run) |
| Base packages | tools we use (`curl`, `jq`, `htop`, `unzip`); `python3-debian` is needed by the `deb822_repository` module |
| `20auto-upgrades` | Ubuntu installs security updates by itself every day |
| Swap file (2 GB) | **swap** = disk space used as emergency memory. t3.small has only 2 GB RAM; without swap, a memory spike (Prometheus, a Docker build) makes Linux kill a process (OOM killer) |
| `creates:` + handler | the file is created once; `mkswap` + `swapon` run only when it was just created |
| Mode `0600` | only root may read swap (it can contain pieces of memory such as passwords) |
| `mount` with `fstype: swap` | adds the line to `/etc/fstab` so swap is enabled again after a reboot |
| `vm.swappiness = 10` | use swap only when RAM is almost full (the default of 60 swaps too early and slows things down) |

**Not done on purpose:**
- **No automatic reboot.** Rebooting the bastion in the middle of a run would cut the connection to the other servers. If `/var/run/reboot-required` exists, reboot by hand at a quiet time.
- **No firewall (ufw).** AWS security groups already filter traffic before it reaches the server.
- **Time zone stays UTC.** That's the server standard, so logs from all servers line up. Grafana shows times in your browser's time zone.

### Role `docker`: Docker Engine from the official repository

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

| Task | Why |
|---|---|
| Remove old packages | Ubuntu's own `docker.io` etc. would clash with the official packages (this is the Docker documentation's first step) |
| Official Docker repository | newest Docker version, plus the `buildx` and `compose` plugins. Ubuntu's `docker.io` is older. `signed_by` = apt checks that packages really come from Docker |
| `suites: distribution_release` | `noble` for Ubuntu 24.04, taken from facts. It still works on the next Ubuntu |
| `architectures` | `amd64` for t3 servers, `arm64` if we ever use Graviton (t4g) |
| `docker-compose-plugin` | gives `docker compose` (the app server runs the app with compose in Phase 7) |
| `daemon.json` log limits | by default container logs grow **forever** and can fill the disk. Here each container keeps at most 3 files × 10 MB |
| `notify: Restart docker` | restart only when the config changed |
| `docker` group | `ubuntu` can run `docker` without `sudo`. **Note:** being in the `docker` group is the same as being root, so only trusted users are added |
| `reset_connection` | group changes only take effect after logging in again; this reconnects so later tasks can already use `docker` |

### Role `caddy`: HTTPS in front of the app and Jenkins

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

<sub>File: `infra/ansible/roles/caddy/handlers/main.yml`</sub>

```yaml
- name: Reload caddy
  ansible.builtin.systemd_service:
    name: caddy
    state: reloaded
```

| Task | Why |
|---|---|
| `assert` | stop with a clear message if a group has no `caddy_site` |
| Official Caddy repository | the version recommended by Caddy (Ubuntu's is older) |
| `validate:` | Ansible writes the new Caddyfile to a temporary file, runs `caddy validate` on it, and replaces the real file **only if it is valid**. A typo can never break the running Caddy |
| `group: caddy`, `0644` | Caddy runs as user `caddy` and must be able to read the file |
| `notify: Reload caddy` | **reload** (not restart) applies the new config without dropping open connections |

**What Caddy does on its own:**

```text
browser ──HTTPS──► Caddy :443 ──HTTP──► 127.0.0.1:3000 (app) / 127.0.0.1:8080 (Jenkins)
           ▲
           └ certificate from Let's Encrypt, requested and renewed automatically
```

1. It sees the site name `notes.16-4-130-144.sslip.io`.
2. **sslip.io** answers DNS for that name with `16.4.130.144`, so the name points to our server without buying a domain.
3. Caddy asks **Let's Encrypt** for a free certificate. Let's Encrypt checks that we control the name by connecting to port 80/443 (that's why app-sg and jenkins-sg allow 80 and 443 from everyone).
4. Caddy redirects `http://` to `https://` and renews the certificate before it expires (every ~60 days).

**`502 Bad Gateway`** now = Caddy and HTTPS work, but nothing is listening on port 3000/8080 yet. The app arrives in Phase 7 and Jenkins in Phase 6.

---

## C19. Reading the output

```text
PLAY [Base setup (all servers)] ************************************************

TASK [Gathering Facts] *********************************************************
ok: [notes-devops-prod-app]
ok: [notes-devops-prod-jenkins]
ok: [notes-devops-prod-monitoring]

TASK [docker : Install Docker Engine and plugins] ******************************
changed: [notes-devops-prod-app]
...

RUNNING HANDLER [docker : Restart docker] **************************************
changed: [notes-devops-prod-app]

PLAY RECAP *********************************************************************
notes-devops-prod-app        : ok=22  changed=12  unreachable=0  failed=0  skipped=0  rescued=0  ignored=0
```

| Recap column | Meaning |
|---|---|
| `ok` | tasks that ran successfully (including `changed` ones) |
| `changed` | tasks that changed something |
| `unreachable` | SSH failed |
| `failed` | tasks that failed |
| `skipped` | `when:` was false |
| `rescued` / `ignored` | errors handled by `rescue:` / `ignore_errors` (not used yet) |

**Goal:** `unreachable=0 failed=0`. On the second run, also `changed=0`.

---

## C20. Command cheat sheet

```bash
source ~/.venvs/ansible/bin/activate           # every new terminal
cd ~/Documents/"nodejs cicd"/infra/ansible     # so ansible.cfg is found

ansible-inventory --graph                      # which servers, which groups
ansible all -m ping                            # can we connect?
ansible-playbook playbooks/site.yml            # configure everything
ansible-playbook playbooks/site.yml --check --diff   # dry run: show what WOULD change
ansible-playbook playbooks/site.yml --limit app      # only the app server
ansible-playbook playbooks/site.yml --list-hosts     # which servers would be touched
ansible-playbook playbooks/site.yml --list-tasks     # which tasks would run
ansible-playbook playbooks/site.yml --start-at-task "Install Caddy"
ansible-playbook playbooks/site.yml -v         # more detail (-vvv = shows SSH commands, for connection problems)
ansible-playbook playbooks/site.yml --syntax-check
ansible-lint playbooks roles                   # style + best-practice check (pip install ansible-lint)
```

| Flag | Meaning |
|---|---|
| `--check` | don't change anything, just report |
| `--diff` | show the changed lines of files |
| `--limit X` | only these servers/groups |
| `-e key=value` | set a variable (strongest) |
| `-v` … `-vvvv` | more output |

---

## C21. Common problems

### `ansible: command not found`
- **Cause:** the virtual environment is not active in this terminal.
- **Fix:** `source ~/.venvs/ansible/bin/activate`.

### `ansible-inventory --graph` shows only `@ungrouped` (no servers)
- **Causes:** the servers are destroyed or stopped; wrong region; AWS credentials missing.
- **Check:** `aws ec2 describe-instances --filters Name=tag:Project,Values=notes-devops --query "Reservations[].Instances[].State.Name"`.
- **Fix:** `terraform apply`, or `aws configure`.

### `Failed to import the required Python library (botocore or boto3)`
- **Cause:** `boto3` is not installed in the environment Ansible runs from.
- **Fix:** `pip install boto3` with the venv active.

### `UNREACHABLE! ... Permission denied (publickey)`
- **Cause:** the wrong key or user, or the key isn't on the server.
- **Check:** `ssh -J ubuntu@BASTION ubuntu@PRIVATE_IP` by hand.

### `UNREACHABLE! ... Connection timed out` (to the bastion)
- **Cause:** your home IP changed, so `admin_cidr` in `terraform.tfvars` is old (jenkins-sg allows SSH only from that IP).
- **Fix:** update `admin_cidr` with the new IP (`curl -s https://checkip.amazonaws.com`) and run `terraform apply`.

### `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` / `Host key verification failed`
- **Cause:** after destroy + apply, a **new** server got an IP that a **previous** server had, so the remembered key doesn't match.
- **Fix:** forget the old key: `ssh-keygen -R 10.20.1.64` (and the bastion's public IP if needed), then run again.

### `Could not get lock /var/lib/dpkg/lock-frontend`
- **Cause:** on a brand-new server, cloud-init or automatic updates are still running apt.
- **Fix:** wait 1–2 minutes and run again (Ansible continues where it is needed; finished steps report `ok`).

### `[WARNING]: Ansible is being run in a world writable directory ... ignoring it as an ansible.cfg source`
- **Fix:** `chmod -R u=rwX,go=rX infra/ansible`.

### `[DEPRECATION WARNING]: The 'tags' host variable is deprecated` and `Found variable using reserved name 'tags'`
- **Cause:** the amazon.aws plugin still adds the old `tags` variable next to `ec2_tags` (so old playbooks keep working). It prints the warning every time, even when you only use `ec2_tags`.
- **Effect:** none; our files use `ec2_tags`. The warning disappears when a future amazon.aws version removes `tags`.
- We do **not** turn off deprecation warnings (`deprecation_warnings=False`), because they warn us early about real changes.

### `head: Unknown option: 1` on the Mac
- **Cause:** the Mac's disk ignores upper/lower case, and conda (`(base)`) has a Perl tool called `HEAD` (it sends HTTP HEAD requests). It comes first in the `PATH`, so `head` runs `HEAD` instead of the normal `head`.
- **Fix:** don't pipe to `head`; let curl print only the status code: `curl -s -o /dev/null -w "%{http_code}\n" URL` (or use `/usr/bin/head -1`).

### Caddy: `rejectedIdentifier ... Cannot issue for "notes.ec2-16-4-130-144.ap-south-1.compute.amazonaws.com" ... forbidden by policy`
- **What happened (in this project):** our first version used a variable called `public_dns_name` for the sslip.io domain. But the aws_ec2 inventory plugin **already** gives every server a variable with that exact name (the AWS DNS name `ec2-16-4-130-144.ap-south-1.compute.amazonaws.com`). Inventory **host** variables beat `group_vars`, so Caddy got the AWS name. Let's Encrypt refuses to issue certificates for `amazonaws.com` names, so it kept retrying and `curl` returned `000`.
- **Fix:** rename our variable to `sslip_domain`, then run `site.yml` again. The template changes, the handler reloads Caddy, and the certificate comes in seconds.
- **How to find it:** `ansible app -b -m shell -a "journalctl -u caddy --no-pager | grep -i '\"error\"' | tail -3"` shows the real reason. `ansible-inventory --host notes-devops-prod-app` shows every variable the plugin already sets.
- **Lesson:** choose clear, project-specific variable names (`sslip_domain`, `caddy_site`). Before inventing a name, check that the inventory doesn't already use it.

### `502 Bad Gateway` from the sslip.io URL
- Not an error in Phase 5: nothing is listening behind Caddy yet.

### Caddy can't get a certificate (`curl` shows an SSL error)
- **Check:** `ansible app -b -a "journalctl -u caddy --no-pager -n 50"`.
- **Common causes:** ports 80/443 not open in the security group; the sslip.io name has the wrong IP (old inventory); Let's Encrypt rate limit (wait, or Caddy falls back to ZeroSSL by itself).

---

## C22. Summary: the whole flow

```text
terraform apply                  →  servers exist (empty Ubuntu + your SSH key + deploy key)
ansible-playbook site.yml        →  every server: updates, swap, Docker
                                     app + Jenkins: Caddy with HTTPS
(Phase 6) jenkins role           →  Jenkins installed and configured as code on the Jenkins server
(Phase 7) deploy playbook        →  Jenkins runs Ansible: write .env from SSM, pull image, start app
(Phase 8) monitoring role        →  Prometheus, Grafana, Loki, ... on the monitoring server
```

| Remember | |
|---|---|
| Terraform creates, Ansible configures | |
| Inventory = which servers; playbook = what to do; role = a reusable job | |
| Modules are idempotent; check with a second run (`changed=0`) | |
| Handlers run only when something changed | |
| Templates + group variables = one file, a different result per server | |
| `--check --diff` before risky changes | |
| Nothing secret goes into these files: secrets come from SSM at deploy time (Phase 7) | |
