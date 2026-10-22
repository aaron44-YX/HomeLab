#!/usr/bin/env bash
#
# backup.sh - back up a LEMP/WordPress site (database + web root)
#
# What it does:
#   1. Dumps the database to a compressed, verified file
#   2. Archives the web root to a compressed, verified file
#   3. Writes SHA-256 checksums
#   4. Deletes backups older than RETENTION_DAYS (only after a successful backup)
#   5. Logs everything; exits non-zero on any failure
#
# Run as root (needs to read the web root). DB credentials come from DB_CNF,
# never from this file.

set -Eeuo pipefail

### ---------- CONFIG: edit these ----------
SITE_NAME="wordpress"
WEB_ROOT="/var/www/wordpress"
DB_NAME="wordpress_db"
DB_CNF="/root/.backup-db.cnf"
BACKUP_DIR="/var/backups/lemp"
RETENTION_DAYS=7
MIN_FREE_MB=500
LOG_FILE="/var/log/lemp-backup.log"
LOCK_FILE="/var/lock/lemp-backup.lock"
### ----------------------------------------

TIMESTAMP="$(date +%F_%H%M)"
DB_FILE="${BACKUP_DIR}/${SITE_NAME}-db-${TIMESTAMP}.sql.gz"
WEB_FILE="${BACKUP_DIR}/${SITE_NAME}-web-${TIMESTAMP}.tar.gz"
SUM_FILE="${BACKUP_DIR}/${SITE_NAME}-${TIMESTAMP}.sha256"

# --- logging ---------------------------------------------------------------
log() {
    # usage: log LEVEL message...
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "${*:2}" | tee -a "$LOG_FILE"
}

# --- error handling --------------------------------------------------------
on_error() {
    local code="$1" line="$2"
    log ERROR "Backup FAILED at line ${line} (exit code ${code})"
    # remove half-written files so they are never mistaken for good backups
    rm -f "${DB_FILE}.partial" "${WEB_FILE}.partial"
    exit "$code"
}
trap 'on_error $? $LINENO' ERR

# --- pre-flight checks -----------------------------------------------------
touch "$LOG_FILE"

[[ $EUID -eq 0 ]]        || { log ERROR "Must run as root"; exit 1; }
[[ -d "$WEB_ROOT" ]]     || { log ERROR "Web root not found: $WEB_ROOT"; exit 1; }
[[ -r "$DB_CNF" ]]       || { log ERROR "DB credentials file not readable: $DB_CNF"; exit 1; }
[[ -d "$BACKUP_DIR" ]]   || { log ERROR "Backup dir not found: $BACKUP_DIR"; exit 1; }

# Only one copy of this script at a time
exec 9>"$LOCK_FILE"
flock -n 9 || { log ERROR "Another backup is already running"; exit 1; }

# Enough disk space?
FREE_MB="$(df --output=avail -m "$BACKUP_DIR" | tail -n 1 | tr -d ' ')"
if (( FREE_MB < MIN_FREE_MB )); then
    log ERROR "Only ${FREE_MB} MB free in ${BACKUP_DIR} (need ${MIN_FREE_MB})"
    exit 1
fi

log INFO "=== Backup started: ${SITE_NAME} ==="

# --- 1. database -----------------------------------------------------------
log INFO "Dumping database '${DB_NAME}'..."
mariadb-dump --defaults-extra-file="$DB_CNF" \
    --single-transaction --quick --triggers \
    "$DB_NAME" | gzip > "${DB_FILE}.partial"

gzip -t "${DB_FILE}.partial"                                    # is the gzip intact?
zcat "${DB_FILE}.partial" | tail -n 1 | grep -q "Dump completed" # did the dump finish?
mv "${DB_FILE}.partial" "$DB_FILE"
log INFO "Database dump OK: $(basename "$DB_FILE") ($(du -h "$DB_FILE" | cut -f1))"

# --- 2. web root -----------------------------------------------------------
log INFO "Archiving web root ${WEB_ROOT}..."
tar -czf "${WEB_FILE}.partial" \
    -C "$(dirname "$WEB_ROOT")" "$(basename "$WEB_ROOT")"

tar -tzf "${WEB_FILE}.partial" > /dev/null                      # can the archive be read?
mv "${WEB_FILE}.partial" "$WEB_FILE"
log INFO "Web archive OK: $(basename "$WEB_FILE") ($(du -h "$WEB_FILE" | cut -f1))"

# --- 3. permissions and checksums -----------------------------------------
chmod 600 "$DB_FILE" "$WEB_FILE"
( cd "$BACKUP_DIR" && sha256sum "$(basename "$DB_FILE")" "$(basename "$WEB_FILE")" > "$SUM_FILE" )
chmod 600 "$SUM_FILE"
log INFO "Checksums written: $(basename "$SUM_FILE")"

# --- 4. retention (runs only if everything above succeeded) ---------------
log INFO "Removing backups older than ${RETENTION_DAYS} days..."
mapfile -t OLD_FILES < <(find "$BACKUP_DIR" -maxdepth 1 -type f \
    -name "${SITE_NAME}-*" -mtime +"$RETENTION_DAYS")
for f in "${OLD_FILES[@]}"; do
    rm -f -- "$f"
    log INFO "Deleted old file: $(basename "$f")"
done

log INFO "=== Backup finished successfully ==="
