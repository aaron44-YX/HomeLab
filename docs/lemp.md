# LEMP Stack: Nginx + PHP-FPM + MariaDB, running WordPress

**Status:** complete on the LAN, 2026-10-21
**Server:** `homelab` (Ubuntu Server 24.04 LTS, headless, fixed IP `192.168.1.200`), managed from a Linux Mint laptop over SSH.

This runbook records how I built a LEMP stack, how I secured MariaDB, what I broke on purpose, and what I got wrong by accident. Screenshots are in `docs/img/lemp/`. Passwords, salts and keys are never committed; the DB password in the screenshots is redacted.

---

## 1. Architecture

```
Browser (laptop)
   |  http://wp.lab.local  (name set in the laptop's /etc/hosts)
   v
Nginx :80  --- static file? --> served directly from /var/www/wordpress
   |
   | *.php ? --> fastcgi_pass unix:/run/php/php8.3-fpm.sock
   v
PHP-FPM 8.3 (runs as www-data)
   |
   | mysqli over localhost
   v
MariaDB 10.11 (listens on 127.0.0.1:3306 only)
```

| Component | Version / value | Where I saw it |
|-----------|-----------------|----------------|
| OS | Ubuntu 24.04 LTS, kernel 6.8 | SSH login banner |
| PHP-FPM | 8.3 (`php8.3-fpm.service`) | `img/lemp/01` |
| MariaDB | 10.11.14 | `img/lemp/07` |
| WordPress | 7.1.3 | admin footer, `img/lemp/11` |
| Web root | `/var/www/wordpress` | |
| PHP socket | `/run/php/php8.3-fpm.sock` (owner `www-data`) | `img/lemp/01` |

---

## 2. PHP-FPM and Nginx

### Install

```bash
sudo apt install -y php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-zip php-intl
systemctl status php8.3-fpm --no-pager
ls -l /run/php/
grep -E '^(user|group|listen)' /etc/php/8.3/fpm/pool.d/www.conf
```

PHP-FPM was active and enabled. The pool runs as `www-data`, and listens on `/run/php/php8.3-fpm.sock` with `www-data` as socket owner and group (`img/lemp/01`). That ownership matters: Nginx also runs as `www-data`, so it is allowed to talk to the socket.

### A separate test site on port 8081

I did not touch my Phase 2 site. I built a throwaway server block on port 8081 (`/etc/nginx/sites-available/phptest`), opened that port in ufw for the LAN subnet only, and tested there.

The important part is the PHP location:

```nginx
location ~ \.php$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:/run/php/php8.3-fpm.sock;
}
```

### What `snippets/fastcgi-php.conf` does

I read the file instead of just including it (`img/lemp/01`):

- Splits the URL into the script name and any extra path (`fastcgi_split_path_info`).
- `try_files $fastcgi_script_name =404;` checks that the PHP file really exists *before* passing it to PHP. A missing `.php` file gets a clean 404 from Nginx instead of reaching PHP.
- Works around the way `try_files` resets `$fastcgi_path_info`, by saving it into `$path_info` and passing it as `PATH_INFO`.
- Sets `fastcgi_index index.php` and includes `fastcgi.conf`, which holds the standard FastCGI parameters.

### Failure tests (broke it on purpose, then fixed it)

| Test | What I did | Result | Log evidence |
|------|------------|--------|--------------|
| Wrong socket path | Changed the socket in the server block to `php-wrong.sock`, reloaded | **502 Bad Gateway** (`img/lemp/02`) | `connect() to unix:/run/php/php-wrong.sock failed (2: No such file or directory)` |
| PHP-FPM stopped | `sudo systemctl stop php8.3-fpm` | **502 Bad Gateway** (`img/lemp/03`) | `connect() to unix:/run/php/php8.3-fpm.sock failed (2: No such file or directory)` |
| Missing PHP file | Requested `/nope.php` | **404 Not Found** from Nginx (`img/lemp/04`) | The `try_files ... =404` line in the snippet |

What I learned:

- A **502** means Nginx is fine but cannot reach whatever is behind it. The error log (`/var/log/nginx/phptest.error.log`) says exactly why.
- When PHP-FPM is stopped, its socket file disappears, so the message is "No such file or directory", not "Connection refused". Same symptom (502) as a wrong path, but a different cause. The fix is different too: correct the path in one case, `systemctl start php8.3-fpm` in the other.
- A **404** here is Nginx answering for itself because the file does not exist, which is the difference from a 502, where Nginx is failing to reach PHP.

---

## 3. MariaDB

### Install and check where it listens

```bash
sudo apt install -y mariadb-server
systemctl status mariadb --no-pager
sudo ss -tulpn | grep -E '3306|mariadb|mysql'
```

MariaDB 10.11.14 was active and enabled. `ss` showed it bound to **`127.0.0.1:3306`**, not `0.0.0.0`, so it is not reachable from the network (`img/lemp/07`).

### How I secured MariaDB

I ran `sudo mysql_secure_installation` (`img/lemp/07`, `img/lemp/08`). My answers and the reason for each:

| Prompt | Answer | Why |
|--------|--------|-----|
| Current root password | Enter (none) | Fresh install |
| Switch to unix_socket authentication | Y | DB root authenticates through the Linux user (`sudo`), so there is no DB root password to guess or leak |
| Change the root password | N | Not needed with socket authentication |
| Remove anonymous users | Y | Anonymous users let anyone log in without an account |
| Disallow root login remotely | Y | Root should only ever connect locally |
| Remove the test database | Y | It is accessible to everyone by default |
| Reload privilege tables | Y | Applies the changes immediately |

Note: the script itself said I already had root protected and could safely answer `n` to the socket question. On Ubuntu's MariaDB package, root already uses `unix_socket`, so my `Y` was redundant but harmless.

Verification:

- `sudo mariadb` opens a root console.
- `mariadb -u root -p` (no sudo) is rejected: `ERROR 1698 (28000): Access denied for user 'root'@'localhost'` (`img/lemp/08`). Root can only be reached through sudo.
- MariaDB listens only on `127.0.0.1`.

Summary of the hardening:

1. Root uses unix_socket authentication, so there is no network-guessable root password.
2. Anonymous users removed.
3. Remote root login disabled.
4. Test database removed.
5. Service bound to localhost only.
6. The application gets its own least-privilege user (next section), never root.

### Dedicated database and user for the app

```sql
CREATE DATABASE wordpress_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'wp_user'@'localhost' IDENTIFIED BY '<STRONG_RANDOM_PASSWORD>';
GRANT ALL PRIVILEGES ON wordpress_db.* TO 'wp_user'@'localhost';
FLUSH PRIVILEGES;
```

The password came from `openssl rand -base64 24`. Why it is built this way:

- `'wp_user'@'localhost'`: this account can only connect from the server itself.
- `wordpress_db.*`: privileges are limited to one database. If WordPress is compromised, the attacker does not get the other databases or the `mysql` system schema.

Proof of least privilege: logging in as `wp_user` and running `SHOW DATABASES;` lists only `information_schema` and `wordpress_db` (`img/lemp/09`).

### PHP can reach the database

A temporary `dbtest.php` using `mysqli` connected as `wp_user`, and the page returned `DB connection OK` (`img/lemp/05`). I then deleted the file because it contained the password, and requesting it afterwards returned a 404 (`img/lemp/06`).

---

## 4. WordPress deployment

### Files and permissions

```bash
cd /tmp
curl -LO https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
sudo mkdir -p /var/www/wordpress
sudo cp -a /tmp/wordpress/. /var/www/wordpress/
rm -rf /tmp/wordpress /tmp/latest.tar.gz
sudo chown -R www-data:www-data /var/www/wordpress
sudo find /var/www/wordpress -type d -exec chmod 755 {} \;
sudo find /var/www/wordpress -type f -exec chmod 644 {} \;
```

- Directories `755`: owner can read, write and enter; everyone else can read and enter.
- Files `644`: owner can read and write; everyone else read only.

### `wp-config.php`

Copied from the sample, then set `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_HOST` and replaced the authentication keys and salts with fresh values from the WordPress.org secret-key API. Because the file holds the DB password:

```bash
sudo chmod 640 /var/www/wordpress/wp-config.php
sudo chown www-data:www-data /var/www/wordpress/wp-config.php
```

The real file is **not** in this repo. A sanitized example is at `configs/wordpress/wp-config.example.php`.

### Hostname

WordPress stores its own URL in the database at install time, so I picked one name before installing and used only that. On the laptop, `/etc/hosts` maps `192.168.1.200` to `wp.lab.local`.

### Nginx server block

Saved in this repo at `configs/nginx/wordpress`. Key parts:

- `try_files $uri $uri/ /index.php?$args;` so pretty permalinks work.
- The same `fastcgi_pass` to the PHP-FPM socket as before.
- Hidden files denied (`location ~ /\.`).
- PHP execution denied inside `wp-content/uploads`, so an uploaded script can never run.
- `client_max_body_size 64M` for uploads.

### Verification

| Check | Result | Evidence |
|-------|--------|----------|
| Installer completed, admin login works | Yes, admin bar visible on the site | `img/lemp/10` |
| Posts created and published | Yes | `img/lemp/10`, `img/lemp/11` |
| Permalinks set to "Post name" | Yes | `img/lemp/12` |
| Pretty permalink loads (`/pig_admin/`), so `try_files` works | Yes | `img/lemp/13` |
| Image upload displays in a post (upload dir writable, size limit fine) | Yes | `img/lemp/13` |
| WordPress tables exist in `wordpress_db` | Yes: `wp_posts`, `wp_users`, `wp_options` and 8 others | `img/lemp/14` |
| My own posts are stored in MariaDB | Yes: `Pig_Admin` (ID 9) and `Hello Wordpress` (ID 7) are `publish`, with their revisions as `inherit` | `img/lemp/16` |

---

## 5. Security review

`sudo ss -tulpin` (`img/lemp/14`, `img/lemp/15`) showed these listeners:

| Port | Process | Exposure | Why it is open |
|------|---------|----------|----------------|
| 22 (v4 and v6) | sshd | all interfaces | Remote administration, keys only |
| 80 (v4 and v6) | nginx | all interfaces | The web sites |
| 8081 | nginx | all interfaces, ufw allows LAN only | Temporary PHP test site, removed afterwards |
| 3306 | mariadbd | **127.0.0.1 only** | Database for the local app only |
| 53 | systemd-resolved | **127.0.0.53 / 127.0.0.54 only** | Local DNS stub resolver |

Services start on boot: `systemctl is-enabled nginx php8.3-fpm mariadb` returned `enabled` for all three (`img/lemp/15`).

### Power-cycle test

The server is only powered on during work sessions, so the stack has to come up by itself. I ran `sudo poweroff` (`img/lemp/15`), powered the machine on again, logged in, and ran:

```bash
uptime -s && systemctl is-active nginx php8.3-fpm mariadb
```

It printed a boot time of `2026-10-21 11:11:52`, after the earlier shutdown at 10:37, and `active` for all three services (`img/lemp/16`). This matches `systemctl is-enabled` returning `enabled` for all three, so the stack starts on boot without help.

Cleanup afterwards: removed the `phptest` symlink from `sites-enabled`, deleted its ufw rule, ran `nginx -t`, reloaded Nginx (`img/lemp/15`).

---

## 6. Mistakes I made and how I fixed them

These are real, from my terminal history.

| Mistake | Symptom | Fix and lesson |
|---------|---------|----------------|
| Typed `curl -0` (zero) instead of `curl -O` | Binary output dumped into the terminal, then `tar` said `latest.tar.gz: No such file` | Used `curl -LO`. `-O` saves the file; `-L` follows redirects. |
| Ran `nginx -t` without `sudo` | `open() "/run/nginx.pid" failed (13: Permission denied)` and "test failed" | Re-ran with `sudo`. The config was fine; my user simply could not read what Nginx needs. |
| `SHOW DATABASE;` instead of `SHOW DATABASES;` | `ERROR 1064 (42000)` syntax error | Corrected the plural. |
| Typed `prototcp` in the ufw delete command | `ERROR: Wrong number of arguments` | Retyped as `proto tcp`, rule deleted. |

---

## 7. What I can explain in an interview

- Why Nginx needs PHP-FPM: Nginx only serves files and proxies; PHP must run in a separate process.
- 502 vs 404 vs 403: 502 means Nginx cannot reach the backend, 404 means the file does not exist, 403 means the file exists but access is denied.
- Why the app uses its own DB user: least privilege, so a hacked app cannot read other databases.
- Why `mysql_secure_installation` matters and what each answer changes.
- Why a socket can be better than TCP for a local backend: no network port to expose, and access is controlled by file permissions.
- Why secrets stay out of Git, and why `wp-config.php` is mode `640`.

---

## 8. Possible improvements (not done yet)

- HTTPS with Let's Encrypt (Phase 10).
- Automated backups of the database and web root, with a tested restore (Phase 4).
- Reproduce this whole setup with an Ansible playbook (Phase 5).
- A rate limit and `fail2ban` for `wp-login.php`.
