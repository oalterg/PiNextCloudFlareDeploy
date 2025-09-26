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

auto_mount_backup() {
    if mountpoint -q "$BACKUP_MOUNTDIR"; then return 0; fi
    if [[ -n "$BACKUP_LABEL" ]] && blkid -L "$BACKUP_LABEL" >/dev/null 2>&1; then
        mount -L "$BACKUP_LABEL" "$BACKUP_MOUNTDIR" || {
            echo "[!] Failed to mount $BACKUP_LABEL."
            exit 1
        }
        return 0
    fi
    # Auto-scan fallback
    local usb_dev
    usb_dev=$(lsblk -o NAME,TYPE,RM,MOUNTPOINT | grep 'disk\|part' | grep -v '^sda\|nvme0n1' | awk '$3=="1" && $4=="" {print "/dev/"$1; exit}')  # Removable, unmounted
    if [[ -n "$usb_dev" ]]; then
        echo "[*] Auto-detected backup drive: $usb_dev"
        local fs_type=$(blkid -o value -s TYPE "$usb_dev" 2>/dev/null)
        if [[ -z "$fs_type" ]]; then
            BACKUP_LABEL="BackupDrive_$(date +%Y%m%d)"
            mkfs.ext4 -F -L "$BACKUP_LABEL" "$usb_dev"  # Only format if no filesystem
            mount -L "$BACKUP_LABEL" "$BACKUP_MOUNTDIR" || exit 1
        else
            BACKUP_LABEL=$(blkid -o value -s LABEL "$usb_dev" 2>/dev/null || "BackupDrive_$(date +%Y%m%d)")
            if [[ -z $(blkid -o value -s LABEL "$usb_dev") ]]; then
                e2label "$usb_dev" "$BACKUP_LABEL"
            fi
            mount "$usb_dev" "$BACKUP_MOUNTDIR" || exit 1
        fi
        echo "BACKUP_LABEL=$BACKUP_LABEL" >> "$ENV_FILE"  # Update .env idempotently
    else
        echo "[!] No external drive found. Using local fallback: $BACKUP_MOUNTDIR (limited space!)"
        mkdir -p "$BACKUP_MOUNTDIR"
    fi
}

# --- Locking ---
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "Backup is already running."; exit 1; }

# --- Staging and Cleanup ---
DATE="$(date +'%Y-%m-%d_%H-%M-%S')"
STAGING_DIR=$(mktemp -d -p "$BACKUP_MOUNTDIR" staging_XXXXXX)  # Secure temp
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
    rm -f "$LOCK_FILE"  # Ensure lock release
}
trap cleanup EXIT INT TERM

# --- Mount Backup Drive ---
auto_mount_backup

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