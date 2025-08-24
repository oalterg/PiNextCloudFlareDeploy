#!/bin/bash
# backup.sh — Resilient Nextcloud backup (data + DB) with staging and retention

set -euo pipefail

# --- Configuration and Initialization ---
REPO_DIR="/opt/raspi-nextcloud-setup"
ENV_FILE="$REPO_DIR/.env"
LOCK_FILE="/var/run/nextcloud-backup.lock"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

# Validate required variables
: "${BACKUP_MOUNTDIR:?BACKUP_MOUNTDIR not set in .env}"
: "${BACKUP_LABEL:?BACKUP_LABEL not set in .env}"
: "${BACKUP_RETENTION:?BACKUP_RETENTION not set in .env}"
: "${NEXTCLOUD_DATA_DIR:?NEXTCLOUD_DATA_DIR not set}"
: "${MYSQL_USER:?}"
: "${MYSQL_PASSWORD:?}"
: "${MYSQL_DATABASE:?}"

# --- Locking ---
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "Backup is already running."; exit 1; }

# --- Staging and Cleanup ---
DATE="$(date +'%Y-%m-%d_%H-%M-%S')"
STAGING_DIR="$BACKUP_MOUNTDIR/.staging_$DATE"
ARCHIVE_PATH="$BACKUP_MOUNTDIR/nextcloud_backup_${DATE}.tar.gz"

# TRAP to ensure cleanup and maintenance mode is turned off on exit/error
cleanup() {
    echo "[*] Cleaning up..."
    # Turn maintenance mode OFF, suppress errors if already off
    if [[ -n "${NC_CID:-}" ]] && docker ps -q --no-trunc | grep -q "$NC_CID"; then
        echo "[*] Ensuring maintenance mode is disabled..."
        docker exec -u www-data "$NC_CID" php occ maintenance:mode --off || true
    fi
    # Remove staging directory
    if [[ -d "$STAGING_DIR" ]]; then
        rm -rf "$STAGING_DIR"
        echo "[*] Staging directory removed."
    fi
}
trap cleanup EXIT INT TERM

# --- Mount Backup Drive ---
mkdir -p "$BACKUP_MOUNTDIR"
if ! mountpoint -q "$BACKUP_MOUNTDIR"; then
  if blkid -L "$BACKUP_LABEL" >/dev/null 2>&1; then
    echo "[*] Mounting backup drive '$BACKUP_LABEL' to $BACKUP_MOUNTDIR..."
    mount -L "$BACKUP_LABEL" "$BACKUP_MOUNTDIR"
  else
    echo "[!] Backup drive with label '$BACKUP_LABEL' not found. Aborting."
    exit 1
  fi
fi

# --- Main Backup Logic ---
echo "=== Starting Nextcloud Backup: $DATE ==="

mkdir -p "$STAGING_DIR/data" "$STAGING_DIR/db" "$STAGING_DIR/config"
NC_CID="$(docker compose -f "$REPO_DIR/docker-compose.yml" ps -q nextcloud)"

echo "[1/6] Checking for sufficient disk space..."
ESTIMATED_DATA_KB=$(du -sk "$NEXTCLOUD_DATA_DIR" | awk '{print $1}')
ESTIMATED_TOTAL_KB=$((ESTIMATED_DATA_KB + 102400)) # Add 100MB for DB/config
AVAILABLE_KB=$(df --output=avail "$BACKUP_MOUNTDIR" | tail -n1)
if [ "$AVAILABLE_KB" -lt "$ESTIMATED_TOTAL_KB" ]; then
    echo "[!] Not enough free space. Available: $((AVAILABLE_KB / 1024)) MB, Needed: $((ESTIMATED_TOTAL_KB / 1024)) MB. Aborting."
    exit 1
fi

echo "[2/6] Enabling maintenance mode..."
docker exec -u www-data "$NC_CID" php occ maintenance:mode --on

echo "[3/6] Dumping database..."
DB_CID="$(docker compose -f "$REPO_DIR/docker-compose.yml" ps -q db)"
docker run --rm \
  --network container:"$DB_CID" \
  -e MYSQL_PWD="$MYSQL_PASSWORD" \
  mysql:8 \
  mysqldump --column-statistics=0 -h 127.0.0.1 -u "$MYSQL_USER" "$MYSQL_DATABASE" \
  > "$STAGING_DIR/db/nextcloud.sql"

echo "[4/6] Copying data and config..."
rsync -a --delete "$NEXTCLOUD_DATA_DIR"/ "$STAGING_DIR/data/"
NC_HTML_VOLUME=$(docker inspect "$NC_CID" --format '{{ range .Mounts }}{{ if eq .Destination "/var/www/html" }}{{ .Name }}{{ end }}{{ end }}')
docker run --rm -v "${NC_HTML_VOLUME}:/volume:ro" -v "$STAGING_DIR/config":/backup alpine \
    sh -c "cp -a /volume/config/. /backup/"

echo "[5/6] Creating compressed archive..."
tar -C "$STAGING_DIR" -czf "$ARCHIVE_PATH" data db config
sync

# Maintenance mode is disabled by the 'trap cleanup' function

echo "[6/6] Applying backup retention policy (keep last $BACKUP_RETENTION)..."
ls -tp "$BACKUP_MOUNTDIR"/nextcloud_backup_*.tar.gz 2>/dev/null | tail -n +$((BACKUP_RETENTION+1)) | xargs -r rm --
echo "--- Backup Complete: $ARCHIVE_PATH ---"
