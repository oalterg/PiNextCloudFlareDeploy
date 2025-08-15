#!/bin/bash
set -euo pipefail

REPO_DIR="/opt/raspi-nextcloud-setup"
ENV_FILE="$REPO_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: $ENV_FILE not found. Run setup.sh first."
    exit 1
fi
source "$ENV_FILE"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <backup_file.tar.gz>"
    echo "Available backups in $BACKUP_DIR:"
    ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null || echo "No backups found."
    exit 1
fi

BACKUP_FILE="$1"

if [[ ! -f "$BACKUP_FILE" ]]; then
    echo "Error: Backup file not found: $BACKUP_FILE"
    exit 1
fi

echo "WARNING: This will overwrite:"
echo "  - Nextcloud data directory: $NEXTCLOUD_DATA_DIR"
echo "  - MariaDB database: $MYSQL_DATABASE"
echo
read -p "Are you absolutely sure you want to proceed? (yes/NO): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Restore aborted."
    exit 0
fi

TMP_DIR="/tmp/nextcloud-restore-$$"

echo "[1/6] Stopping Nextcloud stack..."
docker compose -f "$REPO_DIR/docker-compose.yml" down

echo "[2/6] Extracting backup..."
mkdir -p "$TMP_DIR"
tar -xzf "$BACKUP_FILE" -C "$TMP_DIR"

echo "[3/6] Restoring data directory..."
rsync -a --delete "$TMP_DIR/data/" "$NEXTCLOUD_DATA_DIR/"

echo "[4/6] Restoring database..."
DB_CONTAINER=$(docker ps -a -qf "name=db")
if [[ -z "$DB_CONTAINER" ]]; then
    echo "Starting database container for restore..."
    docker compose -f "$REPO_DIR/docker-compose.yml" up -d db
    sleep 10
    DB_CONTAINER=$(docker ps -qf "name=db")
fi

docker exec -i "$DB_CONTAINER" sh -c \
    "mysql -u root -p$MYSQL_ROOT_PASSWORD $MYSQL_DATABASE" < "$TMP_DIR/db.sql"

echo "[5/6] Restarting Nextcloud stack..."
docker compose -f "$REPO_DIR/docker-compose.yml" up -d

rm -rf "$TMP_DIR"

echo "=== Restore complete! ==="
echo "Restored from: $BACKUP_FILE"
