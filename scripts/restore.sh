#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/common.sh"
RESTORE_LOG_FILE="$LOG_DIR/restore.log"

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
#if ! tar -tf "$BACKUP_FILE" | grep -q "db/nextcloud.sql"; then die "Invalid backup structure."; fi TODO: fix

# --- Restore Logic ---
TMP_DIR=$(mktemp -d -t nextcloud-restore-XXXXXX)
trap 'rm -rf "$TMP_DIR"; log_info "Cleanup done."' EXIT

log_info "Extracting backup to temporary location..."
tar -xzf "$BACKUP_FILE" -C "$TMP_DIR"

# --- Smart Structure Detection ---
# Finds files even if they are nested deep or at root
log_info "Analyzing backup structure..."

# 1. Locate Nextcloud Root via config.php
NC_CONFIG_PATH=$(find "$TMP_DIR" -name "config.php" | head -n 1)
if [[ -z "$NC_CONFIG_PATH" ]]; then
    die "Invalid backup structure: 'config.php' not found."
fi

# 2. Locate SQL Dump
DB_DUMP_PATH=$(find "$TMP_DIR" -name "*.sql" | head -n 1)
if [[ -z "$DB_DUMP_PATH" ]]; then
    die "Invalid backup structure: SQL dump (*.sql) not found."
fi

log_info "Detected Source: $NC_CONFIG_PATH"
log_info "Detected DB Dump: $DB_DUMP_PATH"

log_info "Stopping Nextcloud..."
set_maintenance_mode "--on" || log_error "Could not enable Nextcloud maintenance mode."
docker compose -f "$COMPOSE_FILE" rm -sf nextcloud || die "Docker could not stop Nextcloud service."

log_info "Restoring Nextcloud Data..."
rsync -a --delete "$TMP_DIR/data/" "$NEXTCLOUD_DATA_DIR/" || die "NC Data RSync failed."

log_info "Restoring Nextcloud Config..."
NC_HTML_VOLUME=$(docker volume ls -q -f name=raspi-nextcloud-setup_nextcloud_html)
docker run --rm -v "${NC_HTML_VOLUME}:/volume" -v "$TMP_DIR/config:/backup:ro" alpine \
  sh -c "rm -rf /volume/config/* && cp -a /backup/. /volume/config/" || die "Error restoring Nextcloud config.php"

 
echo "Resetting and restoring Nextcloud database..."
docker compose -f "$REPO_DIR/docker-compose.yml" up -d db
echo "[*] Waiting for DB container to be healthy..."
wait_for_healthy "db" 120 || die "NC Database container failed to get healthy in time."
DB_CID="$(docker compose -f "$REPO_DIR/docker-compose.yml" ps -q db)"
NETWORK_NAME=$(docker inspect "$DB_CID" --format='{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
 
# Drop and recreate database to ensure idempotent restore
docker run --rm \
  --network "$NETWORK_NAME" \
  -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
  mysql:8 \
  sh -c "mysql -h db -u root -e \"DROP DATABASE IF EXISTS $MYSQL_DATABASE; CREATE DATABASE $MYSQL_DATABASE;\"" || die "Error dropping and recreating NC database."

 
# Import dump using mysql:8 client container
docker run --rm \
  --network "$NETWORK_NAME" \
  -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
  -v "$TMP_DIR/db/nextcloud.sql:/restore.sql" \
  mysql:8 \
  sh -c "mysql -h db -u root $MYSQL_DATABASE < /restore.sql" || die "NC Database import failed."

log_info "Restarting Docker Stack..."
profiles=$(get_tunnel_profiles)
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ${profiles} up -d --remove-orphans || log_error "Failure restarting docker stack."

wait_for_healthy "db" 120 || log_warn "Nextcloud DB taking longer to start."
wait_for_healthy "nextcloud" 180 || log_warn "Nextcloud taking longer to start."

log_info "Disabling maintenance mode"
set_maintenance_mode "--off"

log_info "Triggering Nextcloud data scan for all users"
docker exec -u www-data "$(get_nc_cid)" php occ files:scan --all || log_error "Nextcloud file scan failed."

log_info "=== Restore Complete From: $BACKUP_FILE ==="