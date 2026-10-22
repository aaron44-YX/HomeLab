# How I back up and restore my LEMP server

**What this covers:** an automated, verified backup of my WordPress site (database + web files) on an Ubuntu Server 24.04 LEMP stack, and a **tested** restore procedure.

**Built:** 2026-10-21 to 2026-10-22 (three sessions). **Script:** [`scripts/backup.sh`](../scripts/backup.sh)

> A backup I have never restored is a hope, not a backup. The restore test in this document is the main result of this phase, not the script.

---

## 1. Summary

| | |
|---|---|
| Protects | WordPress database `wordpress_db` and web root `/var/www/wordpress` |
| Method | `mariadb-dump` (consistent snapshot) + `tar` + SHA-256 checksums |
| Runs as | root, from root's crontab |
| Retention | 7 days (older files deleted only after a new backup succeeds) |
| Location | `/var/backups/lemp/` (directory mode `700`, files mode `600`) |
| Log | `/var/log/lemp-backup.log` |
| Size per run | about 264 KB database + 35 MB web files |
| Runtime | about 7 seconds |
| Failure behavior | logs an `ERROR` line, removes partial files, exits non-zero, keeps old backups |

**Environment:** Ubuntu Server 24.04, Nginx, PHP 8.3-FPM, MariaDB 10.11, WordPress (table prefix `wp_`).

---

## 2. What a backup run produces

```
/var/backups/lemp/
├── wordpress-db-2026-10-22_2106.sql.gz      # database dump, compressed
├── wordpress-web-2026-10-22_2106.tar.gz     # web root archive
└── wordpress-2026-10-22_2106.sha256         # checksums for both files
```

Files are named by date and time, so they sort naturally and retention can work from file age.

---

## 3. Design decisions

**A dedicated, read-only database user.** The script never uses the MariaDB root user or the WordPress app user. A `backup` user can only read the one database:

```sql
CREATE USER 'backup'@'localhost' IDENTIFIED BY '<long random password>';
GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES ON wordpress_db.* TO 'backup'@'localhost';
FLUSH PRIVILEGES;
```

Check what it can do with `SHOW GRANTS FOR 'backup'@'localhost';`

> TODO: paste the `SHOW GRANTS` output here.

**Credentials in a root-only file, not in the script.** The password lives in `/root/.backup-db.cnf` (mode `600`) and is passed with `--defaults-extra-file`. That keeps it out of the script (so the script is safe to publish), out of `ps` output, and out of shell history.

```ini
[client]
user=backup
password=<password, stored only on the server>
```

![Backup user can read the tables](img/backups/02-backup-user-privileges.png)

**How the script protects the backup itself:**

| Technique | Why |
|---|---|
| `set -Eeuo pipefail` | Stops on any error. `pipefail` matters because `mariadb-dump \| gzip` would otherwise report success even when the dump failed. I demonstrated this myself: without it the pipeline returns `0`, with it `1`. |
| Write to `.partial`, then `mv` | A crash mid-backup never leaves a corrupt file that looks like a good one. |
| `gzip -t`, `tar -tzf`, and a check for `Dump completed` | Proves the files are readable and the dump actually finished. |
| `trap ... ERR` | One place that logs the failure, removes partial files, and returns a non-zero exit code. |
| Retention runs **last** | If tonight's backup fails, old backups are not deleted. |
| `flock` | Two overlapping runs cannot collide. |
| Free-space check (500 MB) | Fails early instead of filling the disk. |
| `chmod 600` and a `700` folder | Backups contain `wp-config.php` and all site data. |

![Site facts and the pipefail demonstration](img/backups/01-site-facts-and-pipefail.png)

---

## 4. A normal run

```
2026-10-22 21:06:03 [INFO] === Backup started: wordpress ===
2026-10-22 21:06:03 [INFO] Dumping database 'wordpress_db'...
2026-10-22 21:06:03 [INFO] Database dump OK: wordpress-db-2026-10-22_2106.sql.gz (264K)
2026-10-22 21:06:03 [INFO] Archiving web root /var/www/wordpress...
2026-10-22 21:06:10 [INFO] Web archive OK: wordpress-web-2026-10-22_2106.tar.gz (35M)
2026-10-22 21:06:10 [INFO] Checksums written: wordpress-2026-10-22_2106.sha256
2026-10-22 21:06:10 [INFO] Removing backups older than 7 days...
2026-10-22 21:06:10 [INFO] === Backup finished successfully ===
```

Exit code `0`, three files created, and `sha256sum -c` reports `OK` for both files:

![First run, log, and checksum check](img/backups/03-first-run-and-checksums.png)

I also looked inside the files, to be sure they contain what I think they contain: the SQL dump begins with `DROP TABLE IF EXISTS` / `CREATE TABLE` statements, and the archive lists the `wordpress/` tree including `wp-config.php`.

---

## 5. Failure testing

A script I have only seen succeed is half tested. I broke it on purpose:

| Test | Result |
|---|---|
| Wrong database password | `Access denied` from `mariadb-dump`, then `[ERROR] Backup FAILED at line 75 (exit code 2)`. No new backup files, old backups untouched. |
| Web root path that does not exist | `[ERROR] Web root not found: /var/www/nope`, exit code `1`. |
| Run as a normal user | `Permission denied`, exit code `126`. The script is mode `750`, owned by root. |
| Retention | I created a file dated 10 days ago with `touch -d "10 days ago"`. The next successful run logged `Deleted old file` and removed it. |

Failure log from the wrong-password test:

```
2026-10-22 21:18:10 [INFO] === Backup started: wordpress ===
2026-10-22 21:18:10 [INFO] Dumping database 'wordpress_db'...
mariadb-dump: Got error: 1045: "Access denied for user 'backup'@'localhost' (using password: YES)" when trying to connect
2026-10-22 21:18:10 [ERROR] Backup FAILED at line 75 (exit code 2)
```

![Wrong-password test](img/backups/04-peek-inside-and-wrong-password-test.png)

![Web root, permission, and retention tests](img/backups/05-failure-and-retention-tests.png)

---

## 6. Scheduling

The script runs from **root's crontab** (it needs to read the web root):

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# m h dom mon dow  command
<TODO: paste the real line from `sudo crontab -l`> /usr/local/sbin/lemp-backup.sh >> /var/log/lemp-backup-cron.log 2>&1
```

`PATH` is set explicitly because cron runs with a minimal environment, which is the usual reason a script works in a terminal but not in cron.

I tested with a temporary every-minute schedule first and confirmed the job fired (`journalctl -u cron`), then switched to the real schedule:

![Cron firing the backup](img/backups/06-cron-running.png)

**Tradeoff I identified:** this server is powered off between work sessions, and cron only runs while the machine is on. A job scheduled for 2 AM would simply never run. So the schedule sits inside my usual working hours, and I also run `sudo /usr/local/sbin/lemp-backup.sh && sudo poweroff` before shutting down. A more robust fix would be `anacron` or a systemd timer with `Persistent=true`, which catches up missed jobs after boot.

---

## 7. Restore procedure (tested)

I restored **side by side** into a throwaway copy of the site, so the live site was never at risk. Names used: database `wordpress_restore_test`, DB user `restoretest`, files in `/var/www/wp-restore-test`, Nginx host `restore.lab.local`.

### 7.1 Pick one backup set and verify it

Pick a **specific timestamp** so the database, files, and checksums all come from the same run:

```bash
sudo -i
cd /var/backups/lemp
ls -1t                                  # choose a timestamp
TS=2026-10-22_2154                      # example
sha256sum -c wordpress-$TS.sha256       # both lines must say OK
```

### 7.2 Restore the database into a new, empty database

```bash
mariadb -e "CREATE DATABASE wordpress_restore_test CHARACTER SET utf8mb4;"
mariadb -e "CREATE USER 'restoretest'@'localhost' IDENTIFIED BY '<test-only password>';"
mariadb -e "GRANT ALL ON wordpress_restore_test.* TO 'restoretest'@'localhost'; FLUSH PRIVILEGES;"
zcat wordpress-db-$TS.sql.gz | mariadb wordpress_restore_test
```

Compare against the live database:

```
live_posts:     11
restored_posts: 11
```

![Checksums verified and post counts matching](img/backups/07-checksum-and-row-count-check.png)

### 7.3 Restore the web files

```bash
mkdir -p /var/www/wp-restore-test
tar -xzf wordpress-web-$TS.tar.gz -C /var/www/wp-restore-test --strip-components=1
chown -R www-data:www-data /var/www/wp-restore-test
diff -rq /var/www/wordpress /var/www/wp-restore-test | head     # should show almost nothing
```

Point the copy at the restored database in its `wp-config.php` (`DB_NAME`, `DB_USER`, `DB_PASSWORD`), and add these above the "stop editing" line so WordPress does not redirect to the live site (it stores its own address in the database):

```php
define( 'WP_HOME',    'http://restore.lab.local' );
define( 'WP_SITEURL', 'http://restore.lab.local' );
```

### 7.4 Serve it with Nginx and look at it

```bash
cp /etc/nginx/sites-available/wordpress /etc/nginx/sites-available/wp-restore-test
nano /etc/nginx/sites-available/wp-restore-test      # server_name -> restore.lab.local, root -> /var/www/wp-restore-test
ln -s /etc/nginx/sites-available/wp-restore-test /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
```

On the laptop I added `192.168.1.200  restore.lab.local` to `/etc/hosts`.

### 7.5 Disaster drill

I destroyed the test copy completely: dropped its database and DB user, deleted its files, and removed its Nginx site. With the server block gone, `restore.lab.local` fell through to my other default site instead of WordPress:

![Test site destroyed](img/backups/10-broken-state.png)

Then I rebuilt everything **from the backup files only**: recreated the database and user, restored the SQL dump, extracted the web archive, re-copied the Nginx server block, re-applied the `wp-config.php` edits, and reloaded Nginx:

![Restore commands, including the errors I hit](img/backups/08-restore-steps-and-fixes.png)

The site came back, served from the backup, with the same content as the live site:

![Restored site at restore.lab.local](img/backups/11-restored-site.png)

### 7.6 Clean up, and confirm the real site is untouched

```bash
rm -f /etc/nginx/sites-enabled/wp-restore-test /etc/nginx/sites-available/wp-restore-test
nginx -t && systemctl reload nginx
rm -rf /var/www/wp-restore-test
mariadb -e "DROP DATABASE IF EXISTS wordpress_restore_test; DROP USER IF EXISTS 'restoretest'@'localhost';"
```

I also removed the `restore.lab.local` line from `/etc/hosts` on the laptop.

![Cleanup](img/backups/09-recovery-and-cleanup.png)

The live site at `wp.lab.local` was running normally throughout:

![Live site intact](img/backups/12-real-site-intact.png)

---

## 8. If the live site were really lost (not executed)

The same procedure, pointed at the real names:

1. Stop Nginx so nothing writes during the restore: `sudo systemctl stop nginx`
2. Verify the checksums of the chosen backup set.
3. Move the damaged folder aside instead of deleting it: `mv /var/www/wordpress /var/www/wordpress.broken`
4. Restore the files: `tar -xzf wordpress-web-$TS.tar.gz -C /var/www` (the archive's top-level folder is `wordpress/`), then `chown -R www-data:www-data /var/www/wordpress`
5. Restore the database: `zcat wordpress-db-$TS.sql.gz | mariadb wordpress_db` (the dump starts each table with `DROP TABLE IF EXISTS`, so it replaces existing tables)
6. Start Nginx, load the site, and check `/var/log/nginx/error.log`.

---

## 9. Problems I hit and how I fixed them

| Problem | Cause | Fix |
|---|---|---|
| `ERROR 1045 Access denied for user 'backup'` right after setup | My first generated password contained `#`. In an option file, `#` starts a comment, so the password was cut off. | Created the user again with a password without special characters (quoting the value is the other option). |
| `diff` and other commands failed with "No such file or directory" | I used the example names from my notes (`wp.lab.local`, database `wordpress`, prefix `wp-`) instead of my real ones. | Used the real names: web root `/var/www/wordpress`, database `wordpress_db`, backup prefix `wordpress-`. Verified them first with `grep` on `wp-config.php` and the Nginx config. |
| `cd /var/backups/lemp: Permission denied` | The directory is mode `700`, owned by root. That is intentional. | Opened a root shell with `sudo -i` for the restore work. |
| `ERROR 1133 Can't find any matching row in the user table` on `GRANT` | I had dropped the `restoretest` user earlier in the drill, and `GRANT` cannot create a user. | `CREATE USER IF NOT EXISTS`, then `GRANT`. |
| `tar: Cannot open: No such file or directory` | The target folder had been deleted. | `mkdir -p` the folder first. |
| `nginx -t` failed on a missing file in `sites-enabled` | I had deleted the file in `sites-available`, which left a dangling symlink in `sites-enabled`. | Recreated the config by copying the working one, then re-linked it. |
| Checksum file did not match the database file I had selected | `ls -1t \| head -1` was run separately for each pattern while the every-minute test job was still creating new files. | Pick one explicit timestamp (`TS=...`) for all three files, as in section 7.1. |
| `git push` rejected, then `refusing to merge unrelated histories` | The GitHub repo already had commits from earlier phases, and my server-side repo was initialized separately. | `git pull origin main --allow-unrelated-histories --no-rebase`, then push. |

---

## 10. Limitations and what I would improve

- **Backups live on the same disk and machine as the site.** If the disk fails, both are lost. Next step: copy backups to my laptop or to free cloud storage (3-2-1 rule).
- **Backups are not encrypted.** They are protected only by file permissions. Anyone with root, or the disk, can read them.
- **Cron only runs while the server is on.** See section 6; `anacron` or a systemd timer would catch up missed runs.
- **Nobody is told when a backup fails.** The failure is logged, but there is no alert. Phase 7 (monitoring) can check that the log is fresh and that the newest backup is recent.
- **Retention is by age, not by count.** That is fine for a daily schedule but I would revisit it if the schedule changes.
- **I tested the restore on the same server.** A stronger test is restoring onto a fresh VM, which Phase 5 (Ansible rebuild test) covers.

---

## Quick reference

| Task | Command |
|---|---|
| Run a backup now | `sudo /usr/local/sbin/lemp-backup.sh` |
| Back up, then shut down | `sudo /usr/local/sbin/lemp-backup.sh && sudo poweroff` |
| See the log | `sudo tail -n 50 /var/log/lemp-backup.log` |
| List backups | `sudo ls -lh /var/backups/lemp/` |
| Verify a backup set | `sudo bash -c 'cd /var/backups/lemp && sha256sum -c wordpress-<TS>.sha256'` |
| Check cron ran | `journalctl -u cron --since "1 day ago"` |
| Show the schedule | `sudo crontab -l` |
