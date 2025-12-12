#!/bin/bash
set -euo pipefail

# Load Common Library
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/common.sh"

# --- Configuration ---
LOCK_FILE="/var/run/nextcloud-backup.lock"
BACKUP_LOG_FILE="$LOG_DIR/backup.log"

# Redirect output to log file if not running interactively
if [ -t 1 ]; then
    : # Running in terminal, allow stdout
else
    exec >> "$BACKUP_LOG_FILE" 2>&1
fi

load_env

# --- Validation ---
: "${BACKUP_RETENTION:?BACKUP_RETENTION not set}"
: "${NEXTCLOUD_DATA_DIR:?NEXTCLOUD_DATA_DIR not set}"
: "${MYSQL_USER:?}"
: "${MYSQL_PASSWORD:?}"
: "${MYSQL_DATABASE:?}"


# --- Locking ---
exec 200>"$LOCK_FILE"
flock -n 200 || die "Backup is already running."

    # --- Staging and Cleanup ---
    DATE="$(date +'%Y-%m-%d_%H-%M-%S')"
    STAGING_DIR=$(mktemp -d -p "$BACKUP_MOUNTDIR" staging_XXXXXX)  # Secure temp
    ARCHIVE_PATH="$BACKUP_MOUNTDIR/nextcloud_backup_${DATE}.tar.gz"

    # TRAP to ensure cleanup and maintenance mode is turned off on exit/error
cleanup() {
    set_maintenance_mode "--off"
    # Remove staging directory
    if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
        rm -rf "$STAGING_DIR"
        log_info "Staging directory removed."
    fi
    rm -f "$LOCK_FILE"  # Ensure lock release
    log_info "Backup cleanup complete."
}
trap cleanup EXIT INT TERM

# --- Main Logic ---
log_info "=== Starting Backup: $(date) ==="

# 1. Mount Check
if ! mountpoint -q "$BACKUP_MOUNTDIR"; then
    log_info "Attempting to mount $BACKUP_MOUNTDIR..."
    mount "$BACKUP_MOUNTDIR" || die "Failed to mount backup drive."
fi

# 2. Disk Space Check
log_info "[1/6] Checking for sufficient disk space..."
ESTIMATED_DATA_KB=$(du -sk "$NEXTCLOUD_DATA_DIR" | awk '{print $1}')
# Dynamically estimate DB size (fallback to 100MB if query fails)
ESTIMATED_DB_KB=$(docker exec "$DB_CID" mariadb -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT ROUND(SUM(data_length + index_length) / 1024) AS size_kb FROM information_schema.tables WHERE table_schema='$MYSQL_DATABASE';" 2>/dev/null | tail -1 || echo "102400")
ESTIMATED_CONFIG_KB=51200  # Conservative for config (50MB)
ESTIMATED_UNCOMPRESSED_KB=$((ESTIMATED_DATA_KB + ESTIMATED_DB_KB + ESTIMATED_CONFIG_KB))
# Peak: ~2.0x for staging + archive (assuming no compression; adjust multiplier if needed)
ESTIMATED_PEAK_KB=$((ESTIMATED_UNCOMPRESSED_KB * 2))
AVAILABLE_KB=$(df --output=avail "$BACKUP_MOUNTDIR" | tail -n1)
log_info "[INFO] Estimated uncompressed: $((ESTIMATED_UNCOMPRESSED_KB / 1024)) MB, Peak: $((ESTIMATED_PEAK_KB / 1024)) MB, Available: $((AVAILABLE_KB / 1024)) MB" >> "$BACKUP_LOG_FILE"
if [ "$AVAILABLE_KB" -lt "$ESTIMATED_PEAK_KB" ]; then
    die "Insufficient disk space. Available: $((AVAILABLE_KB / 1024)) MB, Needed (peak): $((ESTIMATED_PEAK_KB / 1024)) MB. Aborting."
fi

# 3. Prepare Staging
DATE="$(date +'%Y-%m-%d_%H-%M-%S')"
STAGING_DIR=$(mktemp -d -p "$BACKUP_MOUNTDIR" staging_XXXXXX)
ARCHIVE_PATH="$BACKUP_MOUNTDIR/nextcloud_backup_${DATE}.tar.gz"

mkdir -p "$STAGING_DIR/data" "$STAGING_DIR/db" "$STAGING_DIR/config"

# 4. Enable Maintenance Mode
log_info "Enabling NC maintenance mode."
set_maintenance_mode "--on"

# 5. Database Dump
log_info "Dumping database..."
DB_CID=$(docker compose -f "$COMPOSE_FILE" ps -q db)
if [[ -z "$DB_CID" ]]; then die "Database container not found."; fi

docker run --rm \
    --network container:"$DB_CID" \
    -e MYSQL_PWD="$MYSQL_PASSWORD" \
    mysql:8 \
    mysqldump --column-statistics=0 -h 127.0.0.1 -u "$MYSQL_USER" "$MYSQL_DATABASE" \
    > "$STAGING_DIR/db/nextcloud.sql" || die "Database dump failed."

# 6. File Sync
log_info "Syncing data..."
rsync -a --delete "$NEXTCLOUD_DATA_DIR"/ "$STAGING_DIR/data/" || die "Rsync failed."

# 7. Config Sync
log_info "Syncing config..."
NC_CID=$(get_nc_cid)
NC_HTML_VOLUME=$(docker inspect "$NC_CID" --format '{{ range .Mounts }}{{ if eq .Destination "/var/www/html" }}{{ .Name }}{{ end }}{{ end }}')
docker run --rm -v "${NC_HTML_VOLUME}:/volume:ro" -v "$STAGING_DIR/config":/backup alpine \
    sh -c "cp -a /volume/config/. /backup/" || die "Config backup failed."

# 8. Compress
log_info "Compressing archive..."
tar -C "$STAGING_DIR" -czf "$ARCHIVE_PATH" data db config || die "Compression failed."
sync

# 9. Retention Policy
log_info "Applying retention policy (Keep: $BACKUP_RETENTION)..."
OLD_BACKUPS=$(ls -tp "$BACKUP_MOUNTDIR"/nextcloud_backup_*.tar.gz 2>/dev/null | tail -n +$((BACKUP_RETENTION+1)))
if [[ -n "$OLD_BACKUPS" ]]; then
    log_info "Deleting old backups due to retention: $OLD_BACKUPS" >> "$BACKUP_LOG_FILE"
fi
ls -tp "$BACKUP_MOUNTDIR"/nextcloud_backup_*.tar.gz 2>/dev/null | \
    tail -n +$((BACKUP_RETENTION+1)) | xargs -r rm --

log_info "=== Backup Complete: $ARCHIVE_PATH ==="
rm -f "$LOCK_FILE"  # Redundant lock release