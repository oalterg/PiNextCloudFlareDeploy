#!/bin/bash
# backup.sh — Nextcloud backup (data + DB) with staging and retention
set -euo pipefail

REPO_DIR="/opt/raspi-nextcloud-setup"
ENV_FILE="$REPO_DIR/.env"
BACKUP_LABEL="${BACKUP_LABEL:-BackupDrive}"
RETENTION="${BACKUP_RETENTION:-8}"           # keep last N backups

[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${BACKUP_DIR:?BACKUP_DIR not set in .env}"
: "${NEXTCLOUD_DATA_DIR:?NEXTCLOUD_DATA_DIR not set}"
: "${MYSQL_USER:?}"
: "${MYSQL_PASSWORD:?}"
: "${MYSQL_DATABASE:?}"

mkdir -p "$BACKUP_DIR"

# Mount backup drive by label if not mounted
if ! mountpoint -q "$BACKUP_DIR"; then
  if blkid -L "$BACKUP_LABEL" >/dev/null 2>&1; then
    echo "[*] Mounting backup drive label '$BACKUP_LABEL' to $BACKUP_DIR..."
    mount -L "$BACKUP_LABEL" "$BACKUP_DIR"
  else
    echo "[!] Backup drive with label '$BACKUP_LABEL' not found. Aborting."
    exit 1
  fi
fi

DATE="$(date +'%Y-%m-%d_%H-%M-%S')"
STAGING="$BACKUP_DIR/.staging_$DATE"
ARCHIVE="$BACKUP_DIR/nextcloud_backup_${DATE}.tar.gz"

mkdir -p "$STAGING/data" "$STAGING/db"

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
echo "[3/5] Copying data directory..."
rsync -a --delete "$NEXTCLOUD_DATA_DIR"/ "$STAGING/data/"

# Package atomically
echo "[4/5] Creating archive..."
tar -C "$STAGING" -czf "$ARCHIVE" data db
sync

# Maintenance OFF
echo "[5/5] Disabling maintenance mode..."
docker exec -u www-data "$NC_CID" php occ maintenance:mode --off

# Cleanup staging
rm -rf "$STAGING"

# Retention
if [[ "$RETENTION" =~ ^[0-9]+$ ]]; then
  echo "[i] Applying retention: keep last $RETENTION backups"
  ls -tp "$BACKUP_DIR"/nextcloud_backup_*.tar.gz 2>/dev/null | tail -n +$((RETENTION+1)) | xargs -r rm -f
fi

echo "Backup complete: $ARCHIVE"
