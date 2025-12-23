#!/bin/bash
set -euo pipefail

# Load Common Library
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/common.sh"

# --- Configuration ---
LOCK_FILE="/var/run/homebrain-backup.lock"
BACKUP_LOG_FILE="$LOG_DIR/backup.log"
STRATEGY="full"

# Parse Args
while [[ $# -gt 0 ]]; do
  case $1 in
    --strategy)
      STRATEGY="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

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

# --- Locking ---
exec 200>"$LOCK_FILE"
flock -n 200 || die "Backup is already running."

# --- Staging and Cleanup ---
# Determine staging location. Use backup drive to avoid filling OS disk, 
# but ensure we have a fallback or cleaner error if mount fails.
STAGING_BASE="$BACKUP_MOUNTDIR"

# TRAP to ensure cleanup and maintenance mode is turned off on exit/error
cleanup() {
    log_info "Cleaning up..."
    set_maintenance_mode "--off"
    # Attempt to restart services if we crashed mid-backup
    if ! is_stack_running; then
        # Ensure HA is up if we stopped it
        local ha_cid=$(get_ha_cid)
        if [[ -n "$ha_cid" ]]; then docker start "$ha_cid" || true; fi
    fi
    
    # Remove staging directory safely
    if [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]]; then
        rm -rf "$STAGING_DIR"
        log_info "Staging directory removed."
    fi
    rm -f "$LOCK_FILE"  # Ensure lock release
    log_info "Backup cleanup complete."
}
trap cleanup EXIT INT TERM

# --- Main Logic ---
log_info "=== Starting Backup [Strategy: $STRATEGY]: $(date) ==="

# 1. Mount Check
if ! mountpoint -q "$BACKUP_MOUNTDIR"; then
    log_info "Attempting to mount $BACKUP_MOUNTDIR..."
    mount "$BACKUP_MOUNTDIR" || die "Failed to mount backup drive."
fi

# Ensure backup dir is writable
if [ ! -w "$BACKUP_MOUNTDIR" ]; then
    die "Backup mount point is read-only or inaccessible."
fi

# 2. Check Service Health (Required to identify volumes)
HA_CID=$(get_ha_cid)
NC_CID=$(get_nc_cid)
DB_CID=$(get_nc_db_cid)

if [[ -z "$HA_CID" ]]; then log_warn "Home Assistant container not found. Skipping HA backup."; fi

# 3. Disk Space Check
log_info "[1/6] Checking for sufficient disk space..."
# Check DB connectivity for size estimation
wait_for_healthy "db" 60 || die "Database is not healthy, cannot perform backup."
# ensures valid configuration before querying Docker for database ID
DB_CID=$(get_tunnel_profiles >/dev/null; docker compose $(get_compose_args) ps -q db)

ESTIMATED_DATA_KB=$(du -sk "$NEXTCLOUD_DATA_DIR" | awk '{print $1}')
# Dynamically estimate DB size
ESTIMATED_DB_KB=$(docker exec "$DB_CID" mariadb -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT ROUND(SUM(data_length + index_length) / 1024) AS size_kb FROM information_schema.tables WHERE table_schema='$MYSQL_DATABASE';" 2>/dev/null | tail -1 || echo "102400")
ESTIMATED_CONFIG_KB=51200  # Conservative for config (50MB)
ESTIMATED_UNCOMPRESSED_KB=$((ESTIMATED_DATA_KB + ESTIMATED_DB_KB + ESTIMATED_CONFIG_KB))
# Peak: ~2.0x for staging + archive (assuming no compression; adjust multiplier if needed)
ESTIMATED_PEAK_KB=$((ESTIMATED_UNCOMPRESSED_KB * 2))
AVAILABLE_KB=$(df --output=avail "$BACKUP_MOUNTDIR" | tail -n1)

log_info "[INFO] Estimated uncompressed: $((ESTIMATED_UNCOMPRESSED_KB / 1024)) MB, Peak: $((ESTIMATED_PEAK_KB / 1024)) MB, Available: $((AVAILABLE_KB / 1024)) MB"

if [ "$AVAILABLE_KB" -lt "$ESTIMATED_PEAK_KB" ]; then
    die "Insufficient disk space. Available: $((AVAILABLE_KB / 1024)) MB, Needed (peak): $((ESTIMATED_PEAK_KB / 1024)) MB. Aborting."
fi

# 4. Prepare Staging
DATE="$(date +'%Y-%m-%d_%H-%M-%S')"
SUFFIX=""
if [[ "$STRATEGY" == "data_only" ]]; then SUFFIX="_data_only"; fi
STAGING_DIR=$(mktemp -d -p "$STAGING_BASE" staging_XXXXXX)
ARCHIVE_PATH="$BACKUP_MOUNTDIR/homebrain_backup${SUFFIX}_${DATE}.tar.gz"

mkdir -p "$STAGING_DIR/nc_data" "$STAGING_DIR/nc_apps" "$STAGING_DIR/nc_db" "$STAGING_DIR/nc_config" "$STAGING_DIR/ha_config"

# 5. Stop Services / Enable Maintenance Mode
log_info "Preparing services..."
set_maintenance_mode "--on"

# STOP Home Assistant to ensure SQLite DB consistency
if [[ -n "$HA_CID" ]]; then
    log_info "Stopping Home Assistant..."
    docker stop "$HA_CID"
fi

# 6. Database Dump (Full Only)
if [[ "$STRATEGY" == "full" && -n "$DB_CID" ]]; then
    log_info "Dumping Nextcloud Database..."

    # Health check first
    docker run --rm \
        --network container:"$DB_CID" \
        -e MYSQL_PWD="$MYSQL_PASSWORD" \
        mysql:8 \
        mysqladmin -h 127.0.0.1 -u "$MYSQL_USER" ping >/dev/null || die "Database is not responding."

# Then dump (clean output)
    docker run --rm \
        --network container:"$DB_CID" \
        -e MYSQL_PWD="$MYSQL_PASSWORD" \
        mysql:8 \
        mysqldump --column-statistics=0 -h 127.0.0.1 -u "$MYSQL_USER" "$MYSQL_DATABASE" \
        > "$STAGING_DIR/nc_db/nextcloud.sql" || die "Database dump failed."

    # Verify dump is not empty
    if [ ! -s "$STAGING_DIR/nc_db/nextcloud.sql" ]; then
        die "Database dump created but file is empty. Backup aborted."
    fi
fi

# 6.5 Nextcloud Apps (Full Only - To backup installed apps like Passwords)
if [[ "$STRATEGY" == "full" && -n "$NC_CID" ]]; then
    log_info "Syncing Nextcloud Custom User Apps..."

    # 1. Identify the volume mounted at /var/www/html
    NC_VOL=$(docker inspect "$NC_CID" --format '{{ range .Mounts }}{{ if eq .Destination "/var/www/html" }}{{ .Name }}{{ end }}{{ end }}')
    
    # 2. Backup only /custom_apps
    # We mount the whole html volume to /volume, then copy /volume/custom_apps
    docker run --rm -v "${NC_VOL}:/volume:ro" -v "$STAGING_DIR/nc_apps":/backup alpine \
        sh -c "if [ -d /volume/custom_apps ]; then cp -a /volume/custom_apps/. /backup/; fi" || die "NC Apps backup failed."
fi

# 7. Nextcloud Data (Rsync host path)
log_info "Syncing Nextcloud Data..."
rsync -a --delete "$NEXTCLOUD_DATA_DIR"/ "$STAGING_DIR/nc_data/" || die "NC Data Sync failed."

# 8. Nextcloud Config (Helper Container - Full Only)
if [[ "$STRATEGY" == "full" && -n "$NC_CID" ]]; then
    log_info "Syncing Nextcloud Config..."
    NC_VOL=$(docker inspect "$NC_CID" --format '{{ range .Mounts }}{{ if eq .Destination "/var/www/html" }}{{ .Name }}{{ end }}{{ end }}')
    docker run --rm -v "${NC_VOL}:/volume:ro" -v "$STAGING_DIR/nc_config":/backup alpine \
        sh -c "cp -a /volume/config/. /backup/" || die "NC Config backup failed."
fi

# 9. Home Assistant Config (Helper Container - All Strategies)
if [[ -n "$HA_CID" ]]; then
    log_info "Syncing Home Assistant Config..."
    # We use --volumes-from because HA uses a named volume, not a bind mount.
    # Note: HA_CID is stopped, but we can still mount its volumes using the ID.
    docker run --rm --volumes-from "$HA_CID" \
        -v "$STAGING_DIR/ha_config":/backup \
        alpine sh -c "cp -a /config/. /backup/" || die "HA Config backup failed."
fi

# 10. Restart Services
log_info "Resuming services..."
if [[ -n "$HA_CID" ]]; then docker start "$HA_CID"; fi
set_maintenance_mode "--off"

# 11. Compress
log_info "Compressing archive..."
tar -C "$STAGING_DIR" -czf "$ARCHIVE_PATH" . || die "Compression failed."
sync

# 12. Retention
log_info "Applying retention (Keep: $BACKUP_RETENTION)..."
ls -tp "$BACKUP_MOUNTDIR"/homebrain_backup*.tar.gz 2>/dev/null | \
    tail -n +$((BACKUP_RETENTION+1)) | xargs -r rm --

log_info "=== Backup Complete: $ARCHIVE_PATH ==="
# Lock file removed by trap