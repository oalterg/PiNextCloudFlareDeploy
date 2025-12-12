#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/common.sh"
RESTORE_LOG_FILE="$LOG_DIR/restore.log"

if [ -t 1 ]; then :; else exec >> "$RESTORE_LOG_FILE" 2>&1; fi

load_env

# --- Input Parsing ---
BACKUP_FILE="${1:-}"
NO_PROMPT="${2:-false}"

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

# --- Confirmation ---
if [[ "$NO_PROMPT" != "--no-prompt" ]]; then
    echo "WARNING: This will OVERWRITE all data in $NEXTCLOUD_DATA_DIR and the database."
    read -rp "Type 'OVERWRITE' to confirm: " CONFIRM
    if [[ "$CONFIRM" != "OVERWRITE" ]]; then die "Aborted."; fi
fi

# --- Integrity Check ---
log_info "Verifying backup integrity..."
if ! gzip -t "$BACKUP_FILE"; then die "Corrupt backup file."; fi
if ! tar -tf "$BACKUP_FILE" | grep -q "db/nextcloud.sql"; then die "Invalid backup structure."; fi

# --- Restore Logic ---
TMP_DIR=$(mktemp -d -t nextcloud-restore-XXXXXX)
trap 'rm -rf "$TMP_DIR"; log_info "Cleanup done."' EXIT

log_info "Extracting backup..."
tar -xzf "$BACKUP_FILE" -C "$TMP_DIR"

log_info "Stopping Nextcloud..."
set_maintenance_mode "--on" || true
docker compose -f "$COMPOSE_FILE" rm -sf nextcloud

log_info "Restoring Data..."
rsync -a --delete "$TMP_DIR/data/" "$NEXTCLOUD_DATA_DIR/"

log_info "Restoring Config..."
NC_HTML_VOLUME=$(docker volume ls -q -f name=raspi-nextcloud-setup_nextcloud_html)
docker run --rm -v "${NC_HTML_VOLUME}:/volume" -v "$TMP_DIR/config:/backup:ro" alpine \
    sh -c "rm -rf /volume/config/* && cp -a /backup/. /volume/config/"

    echo "[4/6] Resetting and restoring database..."
    docker compose -f "$REPO_DIR/docker-compose.yml" up -d db
    echo "[*] Waiting for DB container to be healthy..."
    wait_for_healthy "db" 120 || exit 1
    DB_CID="$(docker compose -f "$REPO_DIR/docker-compose.yml" ps -q db)"
    NETWORK_NAME=$(docker inspect "$DB_CID" --format='{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')

    # Drop and recreate database to ensure idempotent restore
    docker run --rm \
      --network "$NETWORK_NAME" \
      -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
      mysql:8 \
      sh -c "mysql -h db -u root -e \"DROP DATABASE IF EXISTS $MYSQL_DATABASE; CREATE DATABASE $MYSQL_DATABASE;\""

    # Import dump using mysql:8 client container
    docker run --rm \
      --network "$NETWORK_NAME" \
    -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
    -v "$TMP_DIR/db/nextcloud.sql:/restore.sql" \
    mysql:8 \
      sh -c "mysql -h db -u root $MYSQL_DATABASE < /restore.sql" || die "NC Database import failed."

log_info "Restarting Docker Stack..."
profiles=$(get_tunnel_profiles)
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ${profiles} up -d --remove-orphans

wait_for_healthy "db" 120 || die "DB failed to start."
wait_for_healthy "nextcloud" 180 || die "Nextcloud failed to start."

set_maintenance_mode "--off"
log_info "=== Restore Complete From: $BACKUP_FILE ===