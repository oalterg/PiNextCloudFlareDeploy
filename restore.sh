#!/bin/bash
set -euo pipefail

REPO_DIR="/opt/raspi-nextcloud-setup"
ENV_FILE="$REPO_DIR/.env"
BACKUP_DIR=/mnt/backup
BACKUP_LABEL="BackupDrive" 

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: $ENV_FILE not found. Run setup.sh first."
    exit 1
fi
source "$ENV_FILE"

# === DETECT AND MOUNT BACKUP PARTITION BY LABEL ===
echo "[*] Detecting backup partition with label '$BACKUP_LABEL'..."
BACKUP_PARTITION=$(lsblk -o NAME,LABEL -nr | awk -v label="$BACKUP_LABEL" '$2 == label {print "/dev/"$1}')

if [ -z "$BACKUP_PARTITION" ]; then
    echo "[!] No partition with label '$BACKUP_LABEL' found. Aborting."
    exit 1
fi
echo "[*] Found backup partition: $BACKUP_PARTITION"

mkdir -p "$BACKUP_DIR"
if mountpoint -q "$BACKUP_DIR"; then
    echo "[*] $BACKUP_DIR is already mounted."
else
    echo "[*] Mounting partition with label $BACKUP_LABEL at $BACKUP_DIR..."
    mount -L "$BACKUP_LABEL" "$BACKUP_DIR" || {
        echo "[!] Failed to mount partition $BACKUP_LABEL. Exiting."
        exit 1
    }
fi

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
# Ensure DB container is up
docker compose -f "$REPO_DIR/docker-compose.yml" up -d db
echo "Waiting for database container to become ready..."
sleep 20

DB_CONTAINER=$(docker compose -f "$REPO_DIR/docker-compose.yml" ps -q db)
if [[ -z "$DB_CONTAINER" ]]; then
    echo "Error: Could not determine DB container ID"
    exit 1
fi

LATEST_SQL="$TMP_DIR/db.sql"
if [[ -f "$LATEST_SQL" ]]; then
    echo "Importing SQL dump $LATEST_SQL..."
    docker run --rm \
      --network container:"$DB_CONTAINER" \
      -e MYSQL_PWD="$MYSQL_PASSWORD" \
      mysql:8 \
      mysql -h 127.0.0.1 -u "$MYSQL_USER" "$MYSQL_DATABASE" < "$LATEST_SQL"
    echo "[*] Database restore complete."
else
    echo "[!] No SQL dump found in backup. Skipping DB restore."
fi

echo "[5/6] Restarting Nextcloud stack..."
docker compose -f "$REPO_DIR/docker-compose.yml" up -d

rm -rf "$TMP_DIR"

echo "=== Restore complete! ==="
echo "Restored from: $BACKUP_FILE"
