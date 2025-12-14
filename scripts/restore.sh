#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/common.sh"
RESTORE_LOG_FILE="$LOG_DIR/restore.log"

# Log only if not running interactively (e.g., via a system service)
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
    BACKUP_FILE="$(find "$BACKUP_MOUNTDIR" -maxdepth 1 -name 'nextcloud_backup_*.tar.gz' -print0 | xargs -0 ls -t | head -n1)"
fi

# Hardening: Check for path traversal characters in the selected file name
if [[ "$BACKUP_FILE" != *"nextcloud_backup_"* ]]; then
    die "Invalid or untrusted backup file path detected: $BACKUP_FILE"
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
    die "Backup file not found: $BACKUP_FILE"
fi

# Interactive confirmation for manual CLI runs
if [[ "$ARG_FLAG" != "--no-prompt" ]]; then
    echo "⚠️  WARNING: RESTORE PROCESS INITIATED ⚠️"
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
    die "Failed to create temporary directory on disk."
fi

log_info "Checking for sufficient disk space first"
REQUIRED_SPACE=$(du -sb "$BACKUP_FILE" | cut -f1)
AVAILABLE_SPACE=$(df -B1 "$TMP_DIR" | tail -1 | awk '{print $4}')
if [ "$REQUIRED_SPACE" -gt "$AVAILABLE_SPACE" ]; then
    die "Insufficient space in $TMP_DIR for extraction (need ${REQUIRED_SPACE} bytes, have ${AVAILABLE_SPACE})."
fi

log_info "Extracting backup to temporary location $TMP_DIR..."
tar -xzf "$BACKUP_FILE" -C "$TMP_DIR"

# --- Smart Structure Detection ---
# Finds files even if they are nested deep or at root
log_info "Analyzing backup structure..."

# 1. Locate Nextcloud Root via config.php
# Limit find to a reasonable depth
NC_CONFIG_PATH=$(find "$TMP_DIR" -maxdepth 5 -name "config.php" | head -n 1)
if [[ -z "$NC_CONFIG_PATH" ]]; then
    die "Invalid backup structure: 'config.php' not found."
fi

# 2. Locate SQL Dump
DB_DUMP_PATH=$(find "$TMP_DIR" -maxdepth 5 -name "*.sql" | head -n 1)
if [[ -z "$DB_DUMP_PATH" ]]; then
    die "Invalid backup structure: SQL dump (*.sql) not found."
fi

log_info "Detected Source: $NC_CONFIG_PATH"
log_info "Detected DB Dump: $DB_DUMP_PATH"

log_info "Stopping Nextcloud..."
set_maintenance_mode "--on" || log_error "Could not enable Nextcloud maintenance mode."
# Stop only the Nextcloud service
docker compose -f "$COMPOSE_FILE" rm -sf nextcloud || die "Docker could not stop Nextcloud service."

log_info "Restoring Nextcloud Data..."
rsync -a --delete "$TMP_DIR/data/" "$NEXTCLOUD_DATA_DIR/" || die "NC Data RSync failed."

log_info "Restoring Nextcloud Config..."
NC_HTML_VOLUME=$(docker volume ls -q -f name=raspi-nextcloud-setup_nextcloud_html)
docker run --rm -v "${NC_HTML_VOLUME}:/volume" -v "$TMP_DIR/config:/backup:ro" alpine \
  sh -c "rm -rf /volume/config/* && cp -a /backup/. /volume/config/" || die "Error restoring Nextcloud config.php"

# Extract password and sync database user BEFORE restart ---
log_info "Extracting restored DB password and syncing database user..."
# Use an alpine container to safely read the config file from the restored volume
DB_PASS=$(docker run --rm -v "${NC_HTML_VOLUME}:/volume:ro" alpine sh -c "
    grep dbpassword /volume/config/config.php | sed \"s/.* => '//; s/',.*//\"
")

if [[ -z "$DB_PASS" ]]; then
    log_warn "No dbpassword found in config.php. Skipping password sync. This may lead to startup failure."
else
    log_info "Updating .env file with restored DB password."
    # Update .env to match for consistency (idempotent sed)
    sed -i "s/^MYSQL_PASSWORD=.*/MYSQL_PASSWORD=$DB_PASS/" "$ENV_FILE" || log_warn "Failed to update .env MYSQL_PASSWORD."

    log_info "Resetting and restoring Nextcloud database..."
    docker compose -f "$REPO_DIR/docker-compose.yml" up -d db
    log_info "Waiting for DB container to be healthy..."
    wait_for_healthy "db" 120 || die "NC Database container failed to get healthy in time."
    DB_CID="$(docker compose -f "$REPO_DIR/docker-compose.yml" ps -q db)"
    NETWORK_NAME=$(docker inspect "$DB_CID" --format='{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
 
    # Drop and recreate database to ensure idempotent restore
    docker run --rm \
      --network "$NETWORK_NAME" \
      -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
      mysql:8 \
      sh -c "mysql -h db -u root -e \"DROP DATABASE IF EXISTS $MYSQL_DATABASE; CREATE DATABASE $MYSQL_DATABASE;\"" || die "Error dropping and recreating NC database."

    # Update the 'nextcloud_user' password in the MySQL server itself
    log_info "Syncing Nextcloud DB user password (nextcloud_user) in MySQL server..."
    # Update/create MySQL user with extracted password
    docker run --rm \
      --network "$NETWORK_NAME" \
      -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
      mysql:8 \
      sh -c "mysql -h db -u root -e \"
        CREATE USER IF NOT EXISTS 'nextcloud_user'@'%' IDENTIFIED BY '$DB_PASS';
        ALTER USER 'nextcloud_user'@'%' IDENTIFIED BY '$DB_PASS';
        GRANT ALL PRIVILEGES ON $MYSQL_DATABASE.* TO 'nextcloud_user'@'%';
        FLUSH PRIVILEGES;\"" || log_warn "Failed to sync DB user password — Nextcloud startup will likely fail."

    # Import dump using mysql:8 client container
    # Ensure the .sql path is correctly volume-mounted
    DB_DUMP_FILE_NAME=$(basename "$DB_DUMP_PATH")
    docker run --rm \
      --network "$NETWORK_NAME" \
      -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
      -v "$(dirname "$DB_DUMP_PATH"):/restore_dir:ro" \
      mysql:8 \
      sh -c "mysql -h db -u root $MYSQL_DATABASE < /restore_dir/$DB_DUMP_FILE_NAME" || die "NC Database import failed."
fi


log_info "Restarting Docker Stack..."
# Since .env is updated and DB user is synced, Nextcloud should start successfully.
profiles=$(get_tunnel_profiles)
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ${profiles} up -d --remove-orphans || log_error "Failure restarting docker stack."

# Wait for healthy services
wait_for_healthy "db" 120 || log_warn "Nextcloud DB taking longer to start."
wait_for_healthy "nextcloud" 180 || log_warn "Nextcloud taking longer to start."

log_info "Disabling maintenance mode"
set_maintenance_mode "--off"

log_info "Post-restore hardening: Fixing permissions..."
chown -R 33:33 "$NEXTCLOUD_DATA_DIR" || log_warn "Failed to chown data dir."

log_info "Running upgrade if needed..."
docker compose -f "$COMPOSE_FILE" exec -u www-data nextcloud php occ upgrade || log_warn "Upgrade failed—check Nextcloud logs."

log_info "Running repairs..."
docker compose -f "$COMPOSE_FILE" exec -u www-data nextcloud php occ maintenance:repair || log_warn "Repair failed."
docker compose -f "$COMPOSE_FILE" exec -u www-data nextcloud php occ db:add-missing-indices || log_warn "Index add failed."

log_info "Triggering Nextcloud data scan for all users"
docker exec -u www-data "$(get_nc_cid)" php occ files:scan --all || log_error "Nextcloud file scan failed."

log_info "=== Restore Complete From: $BACKUP_FILE ==="
rm -rf "$TMP_DIR"
