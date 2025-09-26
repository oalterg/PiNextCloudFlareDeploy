#!/bin/bash
# restore.sh — Robust restore of Nextcloud from a .tar.gz backup

set -euo pipefail

# --- Configuration and Initialization ---
REPO_DIR="/opt/raspi-nextcloud-setup"
ENV_FILE="$REPO_DIR/.env"
BACKUP_LABEL="${BACKUP_LABEL:-BackupDrive}"
COMPOSE_FILE="$REPO_DIR/docker-compose.yml"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

# --- Helper Functions ---

# Print a formatted error message and exit.
die() {
    echo "[ERROR] $1" >&2
    exit 1
}

# Helper function to wait for a container to be healthy using `docker inspect`.
wait_for_healthy() {
    local service_name="$1"
    local timeout_seconds="$2"
    local container_id

    echo "Waiting for $service_name to become healthy..."
    
    container_id=$(docker compose -f "$COMPOSE_FILE" ps -q "$service_name" 2>/dev/null)
    if [[ -z "$container_id" ]]; then
        die "Could not find container for service '$service_name'. Please check Docker logs."
    fi

    local end_time=$((SECONDS + timeout_seconds))
    while [ $SECONDS -lt $end_time ]; do
        local status
        # Directly inspect the health status from Docker's metadata.
        status=$(docker inspect --format="{{if .State.Health}}{{.State.Health.Status}}{{end}}" "$container_id" 2>/dev/null || echo "inspecting")
        if [ "$status" == "healthy" ]; then
            echo "✅ $service_name is healthy."
            return 0
        fi
        sleep 5
    done

    die "$service_name container did not become healthy in time. Check logs with 'docker logs $container_id'."
}

# Validate required variables
: "${BACKUP_MOUNTDIR:?BACKUP_MOUNTDIR not set in .env}"
: "${NEXTCLOUD_DATA_DIR:?NEXTCLOUD_DATA_DIR not set}"
: "${MYSQL_USER:?}"
: "${MYSQL_PASSWORD:?}"
: "${MYSQL_DATABASE:?}"
: "${MYSQL_ROOT_PASSWORD:?}"

# --- Temporary Directory and Cleanup ---
TMP_DIR=$(mktemp -d -t nextcloud-restore-XXXXXX)
trap 'echo "[*] Cleaning up temporary directory..."; rm -rf "$TMP_DIR"' EXIT INT TERM

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

# --- Select Backup File ---
if [[ $# -ge 1 ]]; then
  BACKUP_FILE="$1"
else
  echo "[*] No backup file specified. Finding the latest..."
  BACKUP_FILE="$(find "$BACKUP_MOUNTDIR" -maxdepth 1 -name 'nextcloud_backup_*.tar.gz' -print0 | xargs -0 ls -t | head -n1)"
  [[ -n "$BACKUP_FILE" ]] || { echo "No backups found in $BACKUP_MOUNTDIR"; exit 1; }
fi
[[ -f "$BACKUP_FILE" ]] || { echo "Backup not found: $BACKUP_FILE"; exit 1; }
echo "[*] Selected backup for restore: $BACKUP_FILE"

# --- User Confirmation ---
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "This will COMPLETELY OVERWRITE the following:"
echo "  - Nextcloud data: $NEXTCLOUD_DATA_DIR"
echo "  - Nextcloud config"
echo "  - MariaDB database: $MYSQL_DATABASE"
echo "This operation is irreversible."
read -rp "Type 'OVERWRITE' to proceed: " CONFIRM
[[ "${CONFIRM^^}" == "OVERWRITE" ]] || { echo "Restore aborted by user."; exit 0; }

# --- Main Restore Logic ---
echo "[1/6] Stopping and removing Nextcloud container..."
docker compose -f "$REPO_DIR/docker-compose.yml" rm -sf nextcloud

echo "[2/6] Extracting backup to temporary location..."
tar -xzf "$BACKUP_FILE" -C "$TMP_DIR"
[[ -d "$TMP_DIR/data" && -f "$TMP_DIR/db/nextcloud.sql" && -d "$TMP_DIR/config" ]] || \
  { echo "Backup archive is malformed (missing data/, db/, or config/ dirs)."; exit 1; }

echo "[3/6] Restoring data and config directories..."
mkdir -p "$NEXTCLOUD_DATA_DIR"
rsync -a --delete "$TMP_DIR/data/" "$NEXTCLOUD_DATA_DIR/"
# Get volume name idempotently (even if container is stopped)
NC_HTML_VOLUME=$(docker volume ls -q -f name=raspi-nextcloud-setup_nextcloud_html)
docker run --rm -v "${NC_HTML_VOLUME}:/volume" -v "$TMP_DIR/config:/backup:ro" alpine \
    sh -c "rm -rf /volume/config/* && cp -a /backup/. /volume/config/"

echo "[4/6] Resetting and restoring database..."
docker compose -f "$REPO_DIR/docker-compose.yml" up -d db
echo "[*] Waiting for DB container to be healthy..."
wait_for_healthy "db" 120
DB_CID="$(docker compose -f "$REPO_DIR/docker-compose.yml" ps -q db)"
NETWORK_NAME=$(docker inspect "$DB_CID" --format='{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')

# Drop/recreate DB for an idempotent restore
#docker run --rm --network "$NETWORK_NAME" -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb:11.2 \
#  sh -c "mysql -h db -u root -e 'DROP DATABASE IF EXISTS \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\`;'"

# Drop and recreate database to ensure idempotent restore
docker run --rm \
  --network "$NETWORK_NAME" \
  -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
  mysql:8 \
  sh -c "mysql -h db -u root -e \"DROP DATABASE IF EXISTS $MYSQL_DATABASE; CREATE DATABASE $MYSQL_DATABASE;\""

# Import from SQL dump
#docker run --rm --network "$NETWORK_NAME" -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" -v "$TMP_DIR/db/nextcloud.sql:/restore.sql:ro" mariadb:11.2 \
#  sh -c "mysql -h db -u root '$MYSQL_DATABASE' < /restore.sql"

# Import dump using mysql:8 client container
docker run --rm \
  --network "$NETWORK_NAME" \
  -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
  -v "$TMP_DIR/db/nextcloud.sql:/restore.sql" \
  mysql:8 \
  sh -c "mysql -h db -u root $MYSQL_DATABASE < /restore.sql"

echo "[5/6] Starting Nextcloud service..."
docker compose -f "$REPO_DIR/docker-compose.yml" up -d nextcloud

echo "[6/6] Verifying services and exiting maintenance mode..."
echo "[*] Waiting for Nextcloud container to be healthy..."
wait_for_healthy "nextcloud" 180
NC_CID_NEW="$(docker compose -f "/opt/raspi-nextcloud-setup/docker-compose.yml" ps -q nextcloud)"
docker exec -u www-data "$NC_CID_NEW" php occ maintenance:mode --off || true

# Temp dir is cleaned up by the trap
echo "=== Restore Complete From: $BACKUP_FILE ==="
