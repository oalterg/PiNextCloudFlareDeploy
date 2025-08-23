#!/bin/bash
# backup.sh — Nextcloud backup (data + DB) with staging and retention
set -euo pipefail

REPO_DIR="/opt/raspi-nextcloud-setup"
ENV_FILE="$REPO_DIR/.env"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${BACKUP_MOUNTDIR:?BACKUP_MOUNTDIR not set in .env}"
: "${BACKUP_LABEL:?BACKUP_LABEL not set in .env}"
: "${BACKUP_RETENTION:?BACKUP_RETENTION not set in .env}"
: "${NEXTCLOUD_DATA_DIR:?NEXTCLOUD_DATA_DIR not set}"
: "${MYSQL_USER:?}"
: "${MYSQL_PASSWORD:?}"
: "${MYSQL_DATABASE:?}"

mkdir -p "$BACKUP_MOUNTDIR"

# Mount backup drive by label if not mounted
if ! mountpoint -q "$BACKUP_MOUNTDIR"; then
  if blkid -L "$BACKUP_LABEL" >/dev/null 2>&1; then
    echo "[*] Mounting backup drive label '$BACKUP_LABEL' to $BACKUP_MOUNTDIR..."
    mount -L "$BACKUP_LABEL" "$BACKUP_MOUNTDIR"
  else
    echo "[!] Backup drive with label '$BACKUP_LABEL' not found. Aborting."
    exit 1
  fi
fi

DATE="$(date +'%Y-%m-%d_%H-%M-%S')"
STAGING="$BACKUP_MOUNTDIR/.staging_$DATE"
ARCHIVE="$BACKUP_MOUNTDIR/nextcloud_backup_${DATE}.tar.gz"

mkdir -p "$STAGING/data" "$STAGING/db" "$STAGING/config"

# === DYNAMIC DISK SPACE CHECK ===
echo "[*] Estimating backup size..."
ESTIMATED_DATA_KB=$(du -sk "$NEXTCLOUD_DATA_DIR" | awk '{print $1}')
# Add 20% for DB + config + overhead
ESTIMATED_TOTAL_KB=$((ESTIMATED_DATA_KB + ESTIMATED_DATA_KB / 5))

check_space_and_cleanup() {
    AVAILABLE_KB=$(df --output=avail "$BACKUP_MOUNTDIR" | tail -n1)
    echo "[*] Available space: $((AVAILABLE_KB / 1024)) MB, Needed: $((ESTIMATED_TOTAL_KB / 1024)) MB"
    
    if [ "$AVAILABLE_KB" -lt "$ESTIMATED_TOTAL_KB" ]; then
        echo "[!] Not enough free space for backup."
        
        OLDEST_BACKUP=$(find "$BACKUP_MOUNTDIR" -maxdepth 1 -type d -name "nextcloud_backup_*" | sort | head -n 1)
        BACKUP_COUNT=$(find "$BACKUP_MOUNTDIR" -maxdepth 1 -type d -name "nextcloud_backup_*" | wc -l)
        
        if [ "$BACKUP_COUNT" -gt 1 ] && [ -n "$OLDEST_BACKUP" ]; then
            echo "[*] Removing oldest backup: $OLDEST_BACKUP"
            rm -rf "$OLDEST_BACKUP"
            echo "[*] Retrying space check..."
            check_space_and_cleanup
        else
            echo "[!] Only one or no backups exist. Cannot delete further. Aborting."
            exit 1
        fi
    fi
}
check_space_and_cleanup

# Maintenance ON
echo "[1/5] Enabling maintenance mode..."
NC_CID="$(docker compose -f "$REPO_DIR/docker-compose.yml" ps -q nextcloud)"
docker exec -u www-data "$NC_CID" php occ maintenance:mode --on

# DB dump via mysql:8 using network container
echo "[2/5] Dumping database..."
DB_CID="$(docker compose -f "$REPO_DIR/docker-compose.yml" ps -q db)"
docker run --rm \
  --network container:"$DB_CID" \
  -e MYSQL_PWD="$MYSQL_PASSWORD" \
  mysql:8 \
  mysqldump --column-statistics=0 -h 127.0.0.1 -u "$MYSQL_USER" "$MYSQL_DATABASE" \
  > "$STAGING/db/nextcloud.sql"

# Data copy (bind-mounted)
echo "[3/5] Copying nextcloud data directory..."
rsync -a --delete "$NEXTCLOUD_DATA_DIR"/ "$STAGING/data/"

# Config copy from nextcloud_html
echo "[3b/5] Copying nextcloud config directory..."
# NC_HTML_VOLUME="raspi-nextcloud-setup_nextcloud_html"
NC_HTML_VOLUME=$(docker inspect "$NC_CID" \
  --format '{{ range .Mounts }}{{ if eq .Destination "/var/www/html" }}{{ .Name }}{{ end }}{{ end }}')
docker run --rm -v ${NC_HTML_VOLUME}:/volume -v "$STAGING/config":/backup alpine \
    sh -c "cp -a /volume/config/. /backup/"

# Package atomically
echo "[4/5] Creating archive..."
tar -C "$STAGING" -czf "$ARCHIVE" data db config
sync

# Maintenance OFF
echo "[5/5] Disabling maintenance mode..."
docker exec -u www-data "$NC_CID" php occ maintenance:mode --off

# Cleanup staging
rm -rf "$STAGING"

# BACKUP_RETENTION
if [[ "$BACKUP_RETENTION" =~ ^[0-9]+$ ]]; then
  echo "[i] Applying retention: keep last $BACKUP_RETENTION backups"
  ls -tp "$BACKUP_MOUNTDIR"/nextcloud_backup_*.tar.gz 2>/dev/null | tail -n +$((BACKUP_RETENTION+1)) | xargs -r rm -f
fi

echo "Backup complete: $ARCHIVE"
