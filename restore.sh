#!/bin/bash
# restore.sh — Restore Nextcloud (data + DB) from a .tar.gz backup
set -euo pipefail

REPO_DIR="/opt/raspi-nextcloud-setup"
ENV_FILE="$REPO_DIR/.env"
BACKUP_LABEL="${BACKUP_LABEL:-BackupDrive}"

[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${BACKUP_MOUNTDIR:?BACKUP_MOUNTDIR not set in .env}"
: "${NEXTCLOUD_DATA_DIR:?NEXTCLOUD_DATA_DIR not set}"
: "${MYSQL_USER:?}"
: "${MYSQL_PASSWORD:?}"
: "${MYSQL_DATABASE:?}"

mkdir -p "$BACKUP_MOUNTDIR"

# Mount backup drive by label if not mounted
if ! mountpoint -q "$BACKUP_MOUNTDIR"; then
  if blkid -L "$BACKUP_LABEL" >/dev/null 2>&1; then
    echo "[*] Mounting backup drive label '$BACKUP_LABEL' to $BACKUP_MOUNTDIR..."
    mount -L "$BACKUP_LABEL" "$BACKUP_MOUNTDIR"
  else
    echo "[!] Backup drive with label '$BACKUP_LABEL' not found. Aborting."
    exit 1
  fi
fi

# Choose backup file
if [[ $# -ge 1 ]]; then
  BACKUP_FILE="$1"
else
  BACKUP_FILE="$(ls -t "$BACKUP_MOUNTDIR"/nextcloud_backup_*.tar.gz 2>/dev/null | head -n1 || true)"
  [[ -n "$BACKUP_FILE" ]] || { echo "No backups found in $BACKUP_MOUNTDIR"; exit 1; }
fi

[[ -f "$BACKUP_FILE" ]] || { echo "Backup not found: $BACKUP_FILE"; exit 1; }

echo "WARNING: This will overwrite:"
echo "  - Nextcloud data directory: $NEXTCLOUD_DATA_DIR"
echo "  - MariaDB database: $MYSQL_DATABASE"
read -rp "Type 'yes' to proceed: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Restore aborted."; exit 0; }

TMP="/tmp/nextcloud-restore-$$"
mkdir -p "$TMP"

echo "[1/6] Enabling maintenance mode..."
NC_CID="$(docker compose -f "$REPO_DIR/docker-compose.yml" ps -q nextcloud || true)"
if [[ -n "$NC_CID" ]]; then
  docker exec -u www-data "$NC_CID" php occ maintenance:mode --on || true
fi

echo "[2/6] Stopping Nextcloud service (db stays up)..."
docker compose -f "$REPO_DIR/docker-compose.yml" stop nextcloud || true

echo "[3/6] Extracting backup..."
tar -xzf "$BACKUP_FILE" -C "$TMP"
[[ -d "$TMP/data" ]] || { echo "Backup missing data/ directory"; exit 1; }
[[ -f "$TMP/db/nextcloud.sql" ]] || { echo "Backup missing db/nextcloud.sql"; exit 1; }

echo "[4/6] Restoring data directory..."
mkdir -p "$NEXTCLOUD_DATA_DIR"
rsync -a --delete "$TMP/data/" "$NEXTCLOUD_DATA_DIR/"

echo "[5/6] Restoring database..."
docker compose -f "$REPO_DIR/docker-compose.yml" up -d db
echo "Waiting for DB to be ready..."
sleep 20
DB_CID="$(docker compose -f "$REPO_DIR/docker-compose.yml" ps -q db)"
[[ -n "$DB_CID" ]] || { echo "DB container not found"; exit 1; }

# Import using mysql:8 over container network
docker run --rm \
  --network container:"$DB_CID" \
  -e MYSQL_PWD="$MYSQL_PASSWORD" \
  mysql:8 \
  sh -c "mysql -h 127.0.0.1 -u '$MYSQL_USER' '$MYSQL_DATABASE'" < "$TMP/db/nextcloud.sql"

echo "[6/6] Restarting Nextcloud..."
docker compose -f "$REPO_DIR/docker-compose.yml" up -d nextcloud

echo "[*] Disabling maintenance mode..."
NC_CID="$(docker compose -f "$REPO_DIR/docker-compose.yml" ps -q nextcloud)"
docker exec -u www-data "$NC_CID" php occ maintenance:mode --off || true

rm -rf "$TMP"
echo "=== Restore complete from: $BACKUP_FILE ==="
