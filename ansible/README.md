# Ansible: rebuild the homelab server from code

Playbooks and roles that take a fresh Ubuntu Server 24.04 and turn it into the same hardened LEMP server I first built by hand in Phases 1-4: baseline hardening, an Nginx site, and PHP-FPM + MariaDB running WordPress.

The evidence, the mistakes I made and how I fixed them are in the runbook: [docs/ansible.md](../docs/ansible.md).

## What it does

| Playbook | Role(s) | Result |
|----------|---------|--------|
| `01-baseline.yml` | `baseline` | Packages updated, admin user and SSH key, passwordless sudo (lab only), SSH hardened, ufw on (default deny incoming, SSH allowed), unattended-upgrades on, timezone set |
| `02-nginx.yml` | `nginx` | Nginx installed, HTTP allowed in ufw, a static site deployed from a template, config tested with `nginx -t` before every reload |
| `03-lemp.yml` | `nginx`, `lemp` | PHP-FPM 8.3, MariaDB, dedicated database and user, anonymous users and test database removed, WordPress downloaded, configured and installed with WP-CLI (no browser wizard) |
| `site.yml` | all | Runs 01, 02 and 03 in order: one command from a fresh OS to a working site |

## How to run it

**Control node:** Linux Mint laptop with Ansible (`ansible-core` 2.16, Python 3.12).
**Targets:** Ubuntu Server 24.04 with OpenSSH, my public key already copied (`ssh-copy-id`), and a user in the `sudo` group.

```bash
sudo apt install -y ansible
cd ansible
ansible-galaxy collection install -r requirements.yml
```

One-time configuration:

1. Set `ansible_host` for each machine in `inventory/hosts.yml`.
2. Set `admin_user` in `inventory/group_vars/all/vars.yml`.
3. Create the vault password file and the encrypted secrets file (see "Secrets" below).

Run:

```bash
ansible-playbook playbooks/site.yml --syntax-check
ansible-playbook playbooks/site.yml -K        # first run on a fresh host (asks for the sudo password)
ansible-playbook playbooks/site.yml           # later runs: no -K, and it should report changed=0
```

Always run from inside `ansible/`; paths in `ansible.cfg` are relative to it.

## Design decisions

- **Two environments, one codebase.** Inventory groups `rebuild` (a throwaway VirtualBox VM) and `homelab` (the real server). Per-environment names live in `inventory/group_vars/rebuild.yml` and `homelab.yml`.
- **Safe by default.** Every playbook targets `{{ target | default('rebuild') }}`. Touching the real server needs `-e target=homelab` typed on purpose.
- **Develop on the VM.** The baseline disables SSH passwords, so a typo can lock you out. On the VM a snapshot revert fixes that in a minute.
- **Roles, not one long playbook.** `nginx` takes a list (`nginx_sites`), so the same role serves a static site and a PHP site (`php: true` adds the PHP-FPM location).
- **Validate before applying.** `sshd -t` and `visudo -cf` validate files before they are written, `nginx -t` runs before the reload, and the SSH allow rule is added to ufw before the firewall is enabled.
- **Idempotent.** A second run of `01-baseline.yml` and of `03-lemp.yml` reported `changed=0` (see the runbook).

## Secrets

- Passwords live in `inventory/group_vars/all/00_vault.yml`, encrypted with Ansible Vault.
- `vars.yml` only references them (`wp_db_password: "{{ vault_wp_db_password }}"`).
- `.vault_pass` is in `.gitignore` and is never committed.
- `vault.yml.example` shows the variable names with placeholder values.

To create your own:

```bash
openssl rand -base64 32 > .vault_pass && chmod 600 .vault_pass
openssl rand -hex 16                     # run twice: DB password and WordPress admin password
EDITOR=nano ansible-vault create inventory/group_vars/all/00_vault.yml
```

Paste the two variables from `vault.yml.example` with your generated values.

## Layout

```
ansible/
├── ansible.cfg
├── requirements.yml                  # collections: community.general, community.mysql, ansible.posix
├── inventory/
│   ├── hosts.yml                     # homelab (real) and rebuild (VM)
│   └── group_vars/
│       ├── all/vars.yml              # shared variables
│       ├── all/00_vault.yml          # encrypted secrets
│       ├── all/vault.yml.example     # placeholders only
│       ├── homelab.yml               # names for the real server
│       └── rebuild.yml               # names for the VM
├── playbooks/
│   ├── 01-baseline.yml
│   ├── 02-nginx.yml
│   ├── 03-lemp.yml
│   └── site.yml
└── roles/
    ├── baseline/  (tasks, handlers)
    ├── nginx/     (tasks, handlers, templates: site.conf.j2, index.html.j2)
    └── lemp/      (tasks)
```

`group_vars` sits inside `inventory/` on purpose: Ansible only loads it next to the inventory or the playbook.

## What is verified

| Item | Result | Where |
|------|--------|-------|
| Baseline applied to a fresh VM | Applied after one fix (see runbook); SSH reports `passwordauthentication no`, `permitrootlogin no`, `maxauthtries 3`; ufw active, default deny incoming, 22/tcp allowed; password login refused (`Permission denied (publickey)`) | runbook section 3 |
| Baseline idempotent | Second run: `ok=14 changed=0 failed=0` | runbook section 3 |
| Static site by name | `http://rebuild.lab.local/` serves the Ansible-deployed page | runbook section 4 |
| LEMP applied | First clean run `ok=21 changed=5 failed=0`; database `wordpress`, user `wp_user@localhost`, no anonymous users | runbook section 5 |
| LEMP idempotent | Second run: `ok=20 changed=0 failed=0` | runbook section 5 |
| Broken template caught | `nginx -t` failed the play before any reload | runbook section 7 |
| Full rebuild test (fresh OS, one command) | Run 1 `ok=49 changed=23 failed=0`; run 2 `ok=45 changed=0 failed=0` (‹fill in: date›) | runbook section 6 |

## Known limitations

- Passwordless sudo for the admin user is a lab convenience. Production would restrict it.
- WP-CLI is downloaded from its official URL without a checksum check.
- `update_password: on_create` on the database user keeps re-runs idempotent, but it means changing the vault password does not rotate an existing database user.
- `--check` is only meaningful on a host that is already built; on a fresh host, the Nginx and LEMP playbooks cannot dry-run because their packages are not installed yet.
- The real server was not touched. A dry run against it (`-e target=homelab --check --diff`) was not done.
- `ansible-lint` has not been run yet.
