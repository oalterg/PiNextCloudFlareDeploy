#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/common.sh"
RESTORE_LOG_FILE="$LOG_DIR/restore.log"

# Log only if not running interactively
if [ -t 1 ]; then :; else exec >> "$RESTORE_LOG_FILE" 2>&1; fi

load_env

# --- Input Parsing ---
BACKUP_FILE="${1:-}"
ARG_FLAG="${2:-}"

# --- Prerequisites ---
if ! mountpoint -q "$BACKUP_MOUNTDIR"; then
    mount "$BACKUP_MOUNTDIR" || die "Backup drive not mounted."
fi

if [[ -z "$BACKUP_FILE" ]]; then
    # Auto-select latest
    BACKUP_FILE="$(find "$BACKUP_MOUNTDIR" -maxdepth 1 -name '*backup*.tar.gz' -print0 | xargs -0 ls -t | head -n1)"
fi

if [[ -z "$BACKUP_FILE" || ! -f "$BACKUP_FILE" ]]; then
    die "Backup file not found or invalid selection: ${BACKUP_FILE:-None}"
fi

# Interactive confirmation
if [[ "$ARG_FLAG" != "--no-prompt" ]]; then
    echo "⚠️ WARNING: RESTORE PROCESS INITIATED ⚠️"
    echo "Restoring: $BACKUP_FILE"
    echo "This will WIPE ALL DATA in: ${NEXTCLOUD_DATA_DIR:-/home/admin/nextcloud}"
    read -p "Type 'wipe' to confirm: " confirm
    if [[ "$confirm" != "wipe" ]]; then
        echo "Restore aborted by user."
        exit 0
    fi
fi

# --- Integrity Check ---
log_info "Verifying backup integrity..."
if ! gzip -t "$BACKUP_FILE"; then die "Corrupt backup file."; fi

# --- Restore Logic ---
TMP_DIR=$(mktemp -d -p /home/admin)
trap 'rm -rf "$TMP_DIR"; log_info "Cleanup done."' EXIT
if [ ! -d "$TMP_DIR" ]; then
    die "Failed to create temporary directory."
fi

log_info "Checking for sufficient disk space first"
REQUIRED_SPACE=$(gzip -l "$BACKUP_FILE" | awk 'NR==2 {print int($2 * 1.1)}' || echo $(( $(du -sb "$BACKUP_FILE" | cut -f1) * 5 )))
AVAILABLE_SPACE=$(df -B1 "$TMP_DIR" | tail -1 | awk '{print $4}')
if [ "$REQUIRED_SPACE" -gt "$AVAILABLE_SPACE" ]; then
    die "Insufficient space in $TMP_DIR for extraction (need ${REQUIRED_SPACE} bytes, have ${AVAILABLE_SPACE})."
fi

log_info "Extracting backup to temporary location $TMP_DIR..."
tar -xzf "$BACKUP_FILE" -C "$TMP_DIR"

# --- Smart Detection ---
log_info "Analyzing backup structure..."

HAS_NC_DATA=false
HAS_NC_APPS=false
HAS_NC_DB=false
HAS_NC_CONFIG=false
HAS_HA_CONFIG=false

# Check for legacy (root/data) or new (nc_data) folder structures
if [[ -d "$TMP_DIR/nc_data" ]] || [[ -d "$TMP_DIR/data" ]]; then HAS_NC_DATA=true; fi
if [[ -d "$TMP_DIR/nc_apps" ]]; then HAS_NC_APPS=true; fi
if [[ -d "$TMP_DIR/nc_db" ]] || [[ -f "$TMP_DIR/db/nextcloud.sql" ]]; then HAS_NC_DB=true; fi
if [[ -d "$TMP_DIR/nc_config" ]] || [[ -d "$TMP_DIR/config" ]]; then HAS_NC_CONFIG=true; fi
if [[ -d "$TMP_DIR/ha_config" ]]; then HAS_HA_CONFIG=true; fi

log_info "Backup Contents: NC_DATA=$HAS_NC_DATA, NC_DB=$HAS_NC_DB, NC_CONFIG=$HAS_NC_CONFIG, HA=$HAS_HA_CONFIG"

if [ "$HAS_NC_DATA" = false ] && [ "$HAS_HA_CONFIG" = false ]; then
    die "Invalid backup: No Data or HA config found."
fi

# --- Stop Stack ---
log_info "Stopping services..."
# Attempt to enable maintenance mode, but proceed if container is already down
set_maintenance_mode "--on" || true
# Stop Nextcloud and Homeassistant service
docker compose $(get_compose_args) stop nextcloud homeassistant

# --- 1. Restore Nextcloud Data ---
if [ "$HAS_NC_DATA" = true ]; then
    log_info "Restoring Nextcloud Data..."
    SRC="$TMP_DIR/nc_data"; [[ ! -d "$SRC" ]] && SRC="$TMP_DIR/data"

    rsync -a --delete "$SRC/" "$NEXTCLOUD_DATA_DIR/" || die "NC Data RSync failed."
    chown -R 33:33 "$NEXTCLOUD_DATA_DIR"
fi

# --- 2. Restore Home Assistant Config ---
if [ "$HAS_HA_CONFIG" = true ]; then
    log_info "Restoring Home Assistant Config..."
    # Ensure volume exists by creating the container (no start)
    docker compose $(get_compose_args) up --no-start homeassistant
    HA_CID=$(get_ha_cid)
    if [[ -z "$HA_CID" ]]; then die "Home Assistant container ID not found. Check if the service exists."; fi
    # Use helper to copy data INTO the named volume
    # This ensures files inside the volume are owned by root (default for HA docker)
    docker run --rm --volumes-from "$HA_CID" \
    -v "$TMP_DIR/ha_config":/restore_src:ro \
    alpine sh -c "rm -rf /config/* && cp -a /restore_src/. /config/" || die "HA restore failed."
fi

# --- 2.5 Restore Nextcloud Apps (If Present) ---
if [ "$HAS_NC_APPS" = true ]; then
    log_info "Restoring Nextcloud Custom User Apps..."
    
    # Use the same volume discovery logic as config
    if [[ -n "$NC_CID_OLD" ]]; then
        NC_VOL=$(docker inspect "$NC_CID_OLD" --format '{{ range .Mounts }}{{ if eq .Destination "/var/www/html" }}{{ .Name }}{{ end }}{{ end }}')
    else
        NC_VOL=$(docker volume ls -q | grep "nextcloud_html" | head -n1)
    fi
    
    if [[ -z "$NC_VOL" ]]; then die "Could not locate Nextcloud volume."; fi
    
    # Restore specifically to /custom_apps
    docker run --rm -v "${NC_VOL}:/volume" -v "$TMP_DIR/nc_apps:/restore_src:ro" alpine \
        sh -c "mkdir -p /volume/custom_apps && cp -a /restore_src/. /volume/custom_apps/" || die "Error restoring Nextcloud apps"
fi

# --- 3. Restore Nextcloud Config ---
if [ "$HAS_NC_CONFIG" = true ]; then
    log_info "Restoring Nextcloud Config..."
    SRC="$TMP_DIR/nc_config"; [[ ! -d "$SRC" ]] && SRC="$TMP_DIR/config"
    # Dynamically find the volume name used by the specific container instance
    # This handles cases where the folder name (project name) differs from default.
    NC_CID_OLD=$(docker compose $(get_compose_args) ps -a -q nextcloud | head -n1)
    
    if [[ -n "$NC_CID_OLD" ]]; then
        NC_VOL=$(docker inspect "$NC_CID_OLD" --format '{{ range .Mounts }}{{ if eq .Destination "/var/www/html" }}{{ .Name }}{{ end }}{{ end }}')
    else
        # Fallback if container doesn't exist yet (rare)
        NC_VOL=$(docker volume ls -q | grep "nextcloud_html" | head -n1)
    fi
    if [[ -z "$NC_VOL" ]]; then die "Could not locate Nextcloud volume."; fi
    
    docker run --rm -v "${NC_VOL}:/volume" -v "$SRC:/restore_src:ro" alpine \
        sh -c "rm -rf /volume/config/* && cp -a /restore_src/. /volume/config/" || die "Error restoring Nextcloud config.php"
fi

# --- Consolidated DB Password Handling (After Config Restore, Before DB Restore) ---
if [ "$HAS_NC_CONFIG" = true ]; then
    log_info "Extracting restored DB credentials and syncing..."
    # Extract from the restored volume using PHP for safe parsing (final state)
    DB_USER=$(docker run --rm -v "${NC_VOL}:/volume:ro" php:8-cli php -r '
        @include "/volume/config/config.php"; echo $CONFIG["dbuser"] ?? "";
    ') || DB_USER="$MYSQL_USER"  # Fallback to env if extraction fails
    DB_PASS=$(docker run --rm -v "${NC_VOL}:/volume:ro" php:8-cli php -r '
        @include "/volume/config/config.php"; echo $CONFIG["dbpassword"] ?? "";
    ')

    if [[ -z "$DB_PASS" ]]; then
        log_warn "No dbpassword found in config.php. Skipping password sync. This may lead to startup failure."
    else
        # Update .env with restored password
        log_info "Updating .env file with restored DB password."
        
        sed -i "s/^MYSQL_PASSWORD=.*/MYSQL_PASSWORD=$DB_PASS/" "$ENV_FILE" || log_warn "Failed to update .env MYSQL_PASSWORD."
        # Sync DB user credentials (always, even if no DB restore)
        log_info "Syncing Database User Credentials..."
        # Start DB if not already (for sync)
        docker compose $(get_compose_args) up -d db
        wait_for_healthy "db" 60 || die "DB failed to start."
        DB_CID=$(get_nc_db_cid)
        docker run --rm \
          --network container:"$DB_CID" \
          -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
          mysql:8 \
          mysql -h 127.0.0.1 -u root -e "ALTER USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS'; FLUSH PRIVILEGES;" || log_warn "Failed to sync DB password. Nextcloud may be unhealthy."
    fi
fi

# --- 4. Restore Database ---
if [ "$HAS_NC_DB" = true ]; then
    log_info "Restoring Nextcloud Database..."
    # DB should already be up from password sync or start here
    docker compose $(get_compose_args) up -d db
    wait_for_healthy "db" 60 || die "DB failed to start."
    DB_CID=$(get_nc_db_cid)
    
    # 4a. Import SQL
    SQL_FILE=$(find "$TMP_DIR" -name "*.sql" | head -n 1)
    if [[ -f "$SQL_FILE" ]]; then
        log_info "Importing SQL Dump..."
        docker run --rm \
          --network container:"$DB_CID" \
          -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
          -v "$(dirname "$SQL_FILE"):/restore_dir:ro" \
          mysql:8 \
          sh -c "mysql -h 127.0.0.1 -u root -e 'DROP DATABASE IF EXISTS $MYSQL_DATABASE; CREATE DATABASE $MYSQL_DATABASE;' && mysql -h 127.0.0.1 -u root $MYSQL_DATABASE < /restore_dir/$(basename "$SQL_FILE")" || die "DB Import failed."
    fi
fi

# --- Restart ---
log_info "Restarting Docker Stack..."
profiles=$(get_tunnel_profiles)
docker compose --env-file "$ENV_FILE" $(get_compose_args) ${profiles} up -d --remove-orphans || log_error "Failure restarting docker stack."

wait_for_healthy "nextcloud" 180 || log_warn "Nextcloud taking longer to start."
if [ "$HAS_HA_CONFIG" = true ]; then
wait_for_healthy "homeassistant" 120 || log_warn "HomeAssistant taking longer to start."
fi

# Re-apply Proxy/Tunnel Configuration ---
# The restored config.php contains OLD trusted_domains/proxies from the backup time.
# We must overwrite them with the CURRENT environment settings immediately.
log_info "Updating restored config with current Tunnel and Proxy settings..."

# Safety: Ensure defaults exist if missing in .env to prevent 'set -u' crash
export TRUSTED_PROXIES_0="${TRUSTED_PROXIES_0:-127.0.0.1}"
export TRUSTED_PROXIES_1="${TRUSTED_PROXIES_1:-172.16.0.0/12}"

configure_nc_ha_proxy_settings || log_warn "Failed to apply proxy settings. External access might be broken."

# Restart to apply proxy settings (Safe restart)
# We do not restart DB here, only the frontends
log_info "Restarting NC & HA frontends to apply proxy settings."
docker compose $(get_compose_args) restart nextcloud homeassistant
wait_for_healthy "nextcloud" 120 || log_error "Nextcloud failed to get healthy after proxy config" 
wait_for_healthy "homeassistant" 120 || log_error "Homeassistant failed to get healthy after proxy config" 

log_info "Disabling maintenance mode"
set_maintenance_mode "--off"

# Trigger Repairs/Scan
if [ "$HAS_NC_DATA" = true ]; then
    log_info "Running post-restore upgrade if needed..."
    docker compose $(get_compose_args) exec -u www-data nextcloud php occ upgrade || log_warn "Upgrade failed—check Nextcloud logs."
    
    log_info "Running post-restore repairs..."
    
    docker compose $(get_compose_args) exec -u www-data nextcloud php occ maintenance:repair || log_warn "Repair failed."
    docker compose $(get_compose_args) exec -u www-data nextcloud php occ db:add-missing-indices || log_warn "Index add failed."
    
    log_info "Triggering Nextcloud data scan for all users"
    docker exec -u www-data "$(get_nc_cid)" php occ files:scan --all || log_error "Nextcloud file scan failed."
fi

log_info "=== Restore Complete From: $BACKUP_FILE ==="
rm -rf "$TMP_DIR"
