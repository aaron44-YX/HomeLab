# Ansible: rebuilding the LEMP server from code

**Status:** playbooks written and run against a VirtualBox rebuild VM, 2026-10-27 to 2026-11-02
**Control node:** Linux Mint laptop, `ansible-core` 2.16.3 (`ansible` 9.2.0), Python 3.12.3
**Target:** Ubuntu Server 24.04.5 LTS VM (VirtualBox, bridged network), named `labvm`
**Code:** [`ansible/`](../ansible/README.md)

This runbook records how I turned Phases 1-4 into Ansible code, what I verified, what I broke on purpose, and what I got wrong by accident. Screenshots are in `docs/img/ansible/`. Secrets are never committed; the one place a password appeared on screen is blacked out.


---

## 1. Goal and approach

Phases 1-4 were built by typing commands. If that server died I would have to remember all of it. The goal here is to describe the server as code, so one command rebuilds it and a second run changes nothing.

Rules I followed:

- **Develop against a VM, never the real server.** The baseline disables SSH passwords. A typo there can lock me out, and on a VM a snapshot revert fixes that.
- **Playbooks default to the VM.** They target `{{ target | default('rebuild') }}`. The real server needs `-e target=homelab` typed on purpose.
- **Commit after each working step**, on a `phase5-ansible` branch, then merge to `main`.
- **No secrets in Git.** Passwords live in an Ansible Vault file.

| Piece | Choice |
|-------|--------|
| Playbook 1 | `01-baseline.yml`: packages, admin user and key, SSH hardening, ufw, unattended-upgrades |
| Playbook 2 | `02-nginx.yml`: Nginx and a static site from a template |
| Playbook 3 | `03-lemp.yml`: PHP-FPM, MariaDB, dedicated DB user, WordPress installed with WP-CLI |
| Entry point | `site.yml` imports 01, 02 and 03 in order |

---

## 2. Setup

| Step | What I did | Evidence |
|------|------------|----------|
| Git | Branch `phase5-ansible` from `main`, `.gitignore` with `.vault_pass` before any secret existed | |
| Install | `sudo apt install -y ansible`, then `ansible-galaxy collection install -r requirements.yml` (everything was already bundled) | `img/ansible/01-ansible-version.png` |
| VM | Ubuntu Server 24.04.5 in VirtualBox on a bridged network, my key copied with `ssh-copy-id` (the one manual bootstrap step) | `img/ansible/01-ansible-version.png` |
| Inventory | Groups `homelab` (real server) and `rebuild` (VM), shared variables in `group_vars/all/vars.yml`, per-environment names in `group_vars/rebuild.yml` and `homelab.yml` | `img/ansible/02-inventory-and-ping.png` |
| First contact | `ansible rebuild -m ping` returned `pong`; `-a uptime` and `-m setup -a "filter=ansible_distribution*"` worked | `img/ansible/02-inventory-and-ping.png` |

### The idempotency demo

I ran the same ad-hoc command twice:

```bash
ansible rebuild -b -K -m apt -a "name=tree state=present"
```

The first run reported `CHANGED` and installed `tree` (`img/ansible/03-adhoc-first-run-changed.png`). The second reported `SUCCESS` with `"changed": false` (`img/ansible/04-adhoc-second-run-unchanged.png`). That is the whole idea of Ansible: describe the end state, and act only when reality differs.

---

## 3. Playbook 1: baseline

### What it does

| Task | Why |
|------|-----|
| Update the apt cache, upgrade packages, install `ufw`, `unattended-upgrades`, `acl`, `curl`, `git`, `vim`, `htop` | Start from a patched system; `acl` is needed later so Ansible can become `www-data` |
| Set the timezone to `Asia/Manila` | Logs match local time |
| Ensure the admin user exists in `sudo`, install my public key | Key must be in place **before** passwords are disabled |
| Passwordless sudo for the admin user (validated with `visudo -cf`) | Lets automation run unattended. A lab tradeoff, not a production default |
| Create `/run/sshd` | `sshd -t` needs it (see mistake 2) |
| Drop `00-hardening.conf` into `/etc/ssh/sshd_config.d/` (validated with `sshd -t`) | `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `MaxAuthTries 3`, `X11Forwarding no` |
| ufw: allow 22/tcp, default allow outgoing, default deny incoming, enable | The SSH rule goes in **before** the firewall is switched on |
| `20auto-upgrades` for unattended security updates | Patching without relying on me |
| Report if a reboot is required | Detect it, never reboot on my own |

The file is named `00-hardening.conf` on purpose. `sshd` reads `sshd_config.d/*.conf` alphabetically and the first value wins, so a cloud image file such as `50-cloud-init.conf` cannot override my settings.

### Dry run first

```bash
ansible-playbook playbooks/01-baseline.yml --syntax-check
ansible-playbook playbooks/01-baseline.yml --check --diff -K
```

`--check --diff` showed what would change: timezone `Etc/UTC` to `Asia/Manila`, the new sudoers file, the new SSH drop-in, and the ufw changes (`img/ansible/06-baseline-check-diff.png`).

### Result

After the `/run/sshd` fix (mistake 2), the playbook finished with `ok=15 changed=4 failed=0`: the SSH hardening, two ufw tasks and the `ssh` restart handler changed (`img/ansible/08-baseline-applied-sshd-verified.png`).

Verification:

```bash
ansible rebuild -b -m shell -a "sshd -T | grep -E 'passwordauthentication|permitrootlogin|maxauthtries'"
ansible rebuild -b -a "ufw status verbose"
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password <user>@<vm-ip>
```

| Check | Result |
|-------|--------|
| `sshd -T` | `maxauthtries 3`, `permitrootlogin no`, `passwordauthentication no` |
| `ufw status verbose` | active; default deny (incoming), allow (outgoing); `22/tcp` and `22/tcp (v6)` allowed |
| Password login attempt | `Permission denied (publickey).` |

Screenshots: `img/ansible/08-baseline-applied-sshd-verified.png`, `img/ansible/09-baseline-ufw-password-refused.png`.

### Idempotency

A second run, with no `-K` because passwordless sudo now exists, finished with **`ok=14 changed=0 failed=0`** (`img/ansible/10-baseline-idempotent-and-commit.png`). The playbook still prints the "reboot is required" message; I have not rebooted the VM.

---

## 4. Playbook 2: Nginx static site

The `nginx` role installs Nginx, allows port 80, removes the default site, creates the web root, and deploys two templates:

- `site.conf.j2` builds a server block per entry in `nginx_sites` (a PHP location is added only when `php: true`)
- `index.html.j2` is the page for static sites

Before any reload the role runs `nginx -t`. If the config is broken the play stops and the reload handler never fires.

With `rebuild.lab.local` mapped to the VM in my laptop's `/etc/hosts`, the browser showed the page deployed by Ansible: **"It works: rebuild.lab.local. Deployed by Ansible to labvm."** (`img/ansible/11-static-site-by-name.png`).

---

## 5. Playbook 3: LEMP with WordPress

### What it does

| Task | Notes |
|------|-------|
| Install `php8.3-fpm`, `-cli`, `-mysql`, `-curl`, `-gd`, `-intl`, `-mbstring`, `-xml`, `-zip`, `mariadb-server`, `python3-pymysql` | `python3-pymysql` lets the MySQL modules talk to MariaDB |
| Remove anonymous users and the `test` database | The same goals as `mysql_secure_installation` |
| Create database `wordpress` and user `wp_user@localhost` with privileges on that database only | Never the root DB user. Root keeps socket authentication |
| Install WP-CLI to `/usr/local/bin/wp` | Lets the whole WordPress install run without the browser wizard |
| As `www-data`: `wp core download`, `wp config create`, `wp core install` | Each step is guarded (`creates:` or an `is-installed` check) so re-runs do nothing |
| Passwords come from the vault; tasks that handle them use `no_log: true` | Logs stay clean |

### Result

After fixing the vault problem (mistake 3), the run finished with `ok=21 changed=5 failed=0 skipped=1`.

Database check:

```bash
ansible rebuild -b -m shell -a "mariadb -e 'SHOW DATABASES; SELECT user,host FROM mysql.user;'"
```

Databases: `information_schema`, `mysql`, `performance_schema`, `sys`, `wordpress`. Users: `mariadb.sys`, `mysql`, `root`, `wp_user`, all `localhost`. No anonymous user (`img/ansible/14-lemp-db-check.png`).

### Idempotency

A second run finished with **`ok=20 changed=0 failed=0 skipped=2`** (`img/ansible/15-lemp-idempotent.png`).

---

## 6. Rebuild test: fresh OS, one command

This is the test that matters. The VM is reverted to a clean Ubuntu Server install (OpenSSH on, my key copied), then the whole stack is built by a single command.

```bash
time ansible-playbook playbooks/site.yml -K 2>&1 | tee ~/rebuild-run1.log
ansible-playbook playbooks/site.yml          2>&1 | tee ~/rebuild-run2.log
curl -s  http://wp-rebuild.lab.local/ | grep -i "<title>"
curl -sI http://wp-rebuild.lab.local/wp-login.php | head -1
```

| Item | Result |
|------|--------|
| Date | ‹fill in› |
| Starting point | ‹fill in: snapshot name, or a brand-new VM› |
| Manual steps before the command | OS install and `ssh-copy-id` only |
| Wall-clock time of run 1 (`time`) | ‹fill in› |
| Run 1 recap | `ok=49 changed=23 unreachable=0 failed=0 skipped=1` (`img/ansible/20-rebuild-run1-recap.png`) |
| Run 2 recap (target `changed=0`) | `ok=45 changed=0 unreachable=0 failed=0 skipped=2` (`img/ansible/21-rebuild-run2-recap.png`) |
| `<title>` of the WordPress site | ‹fill in: expected `Homelab WordPress`› |
| WordPress admin login works | ‹fill in› |
| Screenshots | Run 1 and run 2 recaps (above); WordPress in the browser ‹fill in› |

The tail of the run 1 log shows WordPress core downloaded, `wp-config.php` created, the installer run, and the Nginx reload handler firing. The tail of the run 2 log shows every task `ok` and the installer skipped.

The earlier runs in sections 3 to 5 built the VM up in layers (baseline, then Nginx, then LEMP). Those layered runs prove each playbook works and is idempotent; this table is the proof that all three work together from nothing.

---

## 7. What I broke on purpose

### Drill: a broken Nginx template

I edited `roles/nginx/templates/site.conf.j2` and added an invalid directive on line 4, then ran `02-nginx.yml`. The server block was deployed, then the **`Test Nginx configuration` task failed** with `unknown directive "broken_test_directive_here" in /etc/nginx/sites-enabled/mysite:4`. The play stopped (`failed=1`) before the reload handler, so Nginx kept serving the old, working config (`img/ansible/16-drill-broken-template.png`).

One consequence to remember: the broken file now sits in `sites-available`, so a later `systemctl restart nginx` would fail. I fixed the template and re-ran the playbook, which rewrote the file, passed `nginx -t` and reloaded Nginx (`ok=11 changed=2 failed=0`, `img/ansible/17-drill-recovery.png`).

---

## 8. What I got wrong by accident

| # | What happened | Cause | Fix and lesson |
|---|---------------|-------|----------------|
| 1 | `01-baseline.yml --check` failed with `UNREACHABLE ... No route to host` (`img/ansible/05-baseline-unreachable-ip.png`) | The VM's DHCP address had changed (`192.168.1.13` earlier, `192.168.1.10` later), so the inventory pointed at a dead address | Updated `ansible_host`. Lesson: give the VM a DHCP reservation or a static address, or the inventory goes stale between sessions |
| 2 | Baseline failed at "Harden SSH": `Missing privilege separation directory: /run/sshd` (`img/ansible/07-baseline-sshd-validate-failure.png`) | `validate: sshd -t -f %s` needs `/run/sshd` to exist, and on the fresh VM it did not at that moment | Added a task that creates `/run/sshd` before the SSH task (commit `98602b8`). The failed run changed nothing in SSH, so password login was never disabled half-way. Lesson: validation commands have their own preconditions |
| 3 | `03-lemp.yml` failed: `'vault_wp_db_password' is undefined` (`img/ansible/12-vault-variable-undefined.png`) | The vault file was found and decrypted (a wrong vault password gives a decryption error, not this), so the variable names or YAML inside it did not match. I could not tell which line from the output | I lost time renaming files and moving `group_vars` around without a hypothesis. What worked: re-create the file with `ansible-vault create`, then prove the variable resolves with `ansible rebuild -m debug -a "msg={{ vault_wp_db_password }}"` (value blacked out in `img/ansible/13-vault-fixed.png`). Lesson: test a variable on its own before re-running a 5-minute playbook |
| 4 | **Two plaintext copies of the vault passwords were committed to the public repo** (commit `dc43a83`): a stray file `ansible/ansible-vault`, and real values inside `vault.yml.example` | I created draft files while fighting mistake 3 and ran `git add .` without reading the staged list | Found during the Phase 5 review. Both passwords only protect a throwaway VM, but the repo is public, so I treated them as leaked: removed the stray file (commit `6955c54`), replaced the example with placeholders, generated two new passwords and re-encrypted the vault so the next rebuild uses new values. The old values remain in Git history and are now dead. Lesson: run `git diff --cached` before every commit, and `git add` named files when secrets are around |
| 5 | After the LEMP run, `curl http://wp-rebuild.lab.local/` returned 200, but the `<title>` was `rebuild.lab.local`, the static site's title, not WordPress (`img/ansible/19-wordpress-wrong-title.png`) | Most likely a lost handler. The first failed LEMP run wrote the WordPress server block and queued an Nginx reload, then failed in the `lemp` role. Ansible drops queued handlers when a host fails. The next run found the file already correct, reported `ok`, queued nothing, so Nginx never loaded the new server block and sent the unknown hostname to the first site | Added `meta: flush_handlers` at the end of the Nginx role's tasks in `roles/nginx/tasks/main.yml` (`img/ansible/22-flush-handlers-fix.png`), so a reload happens before the later roles can fail. On a clean run the handler already fires at the end (`RUNNING HANDLER [nginx : Reload nginx]` in the run 1 log), so the clean rebuild is not affected; the fix protects the failed-then-fixed case. Re-check: ‹fill in: title after the fix›. Lesson: a handler is not guaranteed to run if something fails later in the play |
| 6 | Harmless warnings left in the output | `community.mysql` deprecation notice about `column_case_sensitive`; `Unable to use /var/www/.ansible/tmp as temporary directory` when becoming `www-data` | Ansible falls back to a system temp directory and the tasks succeed. Left as is |

---

## 9. What this does not cover

- **Real-server dry run.** `--check --diff` against the real server (`-e target=homelab`) was not done. The one attempt could not connect (`No route to host` on `192.168.1.200`), and I skipped it. The Nginx and LEMP playbooks should not be applied to the real server anyway, because the Phase 2 and 3 sites already exist there.
- **Lint.** `ansible-lint` has not been run.
- **Reboot.** The baseline reports that a reboot is required; I have not rebooted the VM.
- **Production hardening.** Passwordless sudo, an unchecked WP-CLI download and `update_password: on_create` are lab choices (see the README).

---

## 10. Commands I would use again

```bash
cd ~/HomeLab/ansible
ansible-inventory --graph                           # what Ansible knows
ansible rebuild -m ping                             # connectivity
ansible-playbook playbooks/X.yml --syntax-check     # parse only
ansible-playbook playbooks/X.yml --check --diff     # dry run, show changes
ansible-playbook playbooks/X.yml                    # apply (targets the VM by default)
ansible-playbook playbooks/X.yml -e target=homelab  # target the real server on purpose
ansible-vault view inventory/group_vars/all/00_vault.yml
```

## 11. Git trail

Branch `phase5-ansible`, one commit per working step: skeleton (`949b51c`), baseline (`014c1dc`), Nginx (`dea6693`), LEMP and vault (`dc43a83`), SSH fix (`98602b8`). Merged into `main`, rebased onto the remote after a rejected push, pushed, and tagged `phase5-complete` (`img/ansible/18-merge-push-tag.png`).
