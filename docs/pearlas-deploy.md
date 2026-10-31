# PearlAS + Standalone Mock MIS Deployment Runbook (LAN Staging)

## Overview
- **Target Host:** Ubuntu 24.04 LTS (`homelab@192.168.1.200`)
- **Staging URL:** `http://pearlas.lab.local`
- **MIS Loopback:** `http://127.0.0.1:8081`
- **PHP Version:** PHP 8.3 (Stock Ubuntu) with dedicated FPM pool `pearlas`

---

## Architecture Setup
1. **PearlAS Application:**
   - Code location: `/var/www/pearlas`
   - Assets pre-built locally on Mint laptop (`Node 22.x`, `npm run build`) and synced via `rsync`.
   - SQLite stray files cleaned (`laravel`) and report files removed prior to push.

2. **Standalone Mock MIS Service:**
   - Code location: `/var/www/pearlas-mis`
   - Isolated database (`pearlas_mis`) running on `127.0.0.1:8081`.

3. **Services & Workers:**
   - **PHP-FPM Pool:** `/etc/php/8.3/fpm/pool.d/pearlas.conf` (`ondemand`, max 8 children).
   - **Queue Worker:** `/etc/systemd/system/pearlas-queue.service` managing background OCR and OTP email delivery.
   - **Scheduler:** `/etc/cron.d/pearlas` running Laravel schedule tasks every minute.

---

## Incidents & Troubleshooting Log

### Incident 1: HTTP 401 API Key Mismatch on MIS Verification
- **Symptom:** Admin panel threw `Failed - unavailable` with error: `The MIS rejected the API key (HTTP 401). Check MIS_API_KEY`.
- **Root Cause:** The `MIS_API_KEY` in `/var/www/pearlas/.env` did not match the key defined in `/var/www/pearlas-mis/.env`.
- **Resolution:**
  1. Extracted the key from `/var/www/pearlas-mis/.env`.
  2. Updated `MIS_API_KEY` in `/var/www/pearlas/.env`.
  3. Refreshed application cache via `sudo -u www-data php artisan config:cache` and restarted the queue worker (`sudo -u www-data php artisan queue:restart`).

### Incident 2: Asset Build Missing Prevention
- **Symptom:** Potential HTTP 500 errors if `public/build/manifest.json` is missing.
- **Resolution:** Built frontend production bundle locally on laptop prior to `rsync` deployment, keeping Node dependencies off the production server.

---

## Verification Completed
- [x] Nginx vhosts listening correctly on port 80 and 8081.
- [x] Port 8081 confirmed blocked from LAN / external network.
- [x] Admin login functional.
- [x] MIS enrollment toggled **ON** and verified against student ID `10000001` (Pass).
- [x] Background queue worker processing OCR and mail queues smoothly.

## Part 14: Backup Procedure Verification
Executed database dumps and storage backup on server (`homelab@192.168.1.200`):
1. **PearlAS Database:** `sudo mariadb-dump --single-transaction pearlas | gzip > pearlas-db-$(date +%F).sql.gz`
2. **Mock MIS Database:** `sudo mariadb-dump --single-transaction pearlas_mis | gzip > pearlas-mis-db-$(date +%F).sql.gz`
3. **Uploaded Assets:** `sudo tar -czf pearlas-files-$(date +%F).tar.gz -C /var/www/pearlas storage/app/private`

*Note: Backup archives and `.env` files are stored locally outside of version control for security compliance.*
