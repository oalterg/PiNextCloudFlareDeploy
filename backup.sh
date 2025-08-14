#!/bin/bash
# backup.sh — Nextcloud bind-mounted data + MariaDB backup
# Run manually or via cron
set -euo pipefail

REPO_DIR="/opt/raspi-nextcloud-setup"
ENV_FILE="$REPO_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: $ENV_FILE not found. Run setup.sh first."
    exit 1
fi

# Load environment variables
source "$ENV_FILE"

if [[ -z "${BACKUP_DIR:-}" || -z "${NEXTCLOUD_DATA_DIR:-}" ]]; then
    echo "Error: BACKUP_DIR or NEXTCLOUD_DATA_DIR not set in $ENV_FILE"
    exit 1
fi

if [[ ! -d "$NEXTCLOUD_DATA_DIR" ]]; then
    echo "Error: Nextcloud data directory '$NEXTCLOUD_DATA_DIR' not found"
    exit 1
fi

DATE=$(date +%F_%H-%M-%S)
TMP_DIR="/tmp/nextcloud-backup-$DATE"
mkdir -p "$TMP_DIR"

echo "=== Starting backup for $DATE ==="

# 1. Backup only Nextcloud's data directory (bind mount on host)
echo "[1/3] Copying Nextcloud data..."
rsync -a --delete "$NEXTCLOUD_DATA_DIR/" "$TMP_DIR/data/"

# 2. Backup database
echo "[2/3] Dumping database..."
docker exec db sh -c "mysqldump -u root -p$MYSQL_ROOT_PASSWORD $MYSQL_DATABASE" > "$TMP_DIR/db.sql"

# 3. Compress everything into one tar.gz
BACKUP_FILE="$BACKUP_DIR/nextcloud-backup-$DATE.tar.gz"
echo "[3/3] Compressing backup..."
tar -czf "$BACKUP_FILE" -C "$TMP_DIR" .

# Cleanup temp
rm -rf "$TMP_DIR"

# 4. Cleanup old backups (older than 30 days)
find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +30 -exec rm -f {} \;

echo "=== Backup completed successfully ==="
echo "Backup saved to: $BACKUP_FILE"
