#!/bin/bash
set -euo pipefail

# === CONFIGURATION ===
BACKUP_LABEL="BackupDrive"           # Label of your backup partition
MOUNT_POINT="/mnt/backup"
DATA_DIR="/home/sudo/nextcloud/data"  # Path to Nextcloud data dir
NEXTCLOUD_CONTAINER="nextcloud-nextcloud-1" # Your Nextcloud container name
DB_CONTAINER="nextcloud-db-1"          # Your DB container name
DB_USER="nextcloud"
DB_PASS="pwd"
DB_NAME="nextcloud"
KEEP_DAYS=30                          # Delete backups older than this (as extra cleanup)

# Logging
LOG_FILE="/var/log/nextcloud_backup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Lock file to prevent concurrent runs
LOCKFILE="/tmp/nextcloud_backup.lock"
if [ -f "$LOCKFILE" ]; then
    echo "[!] Another backup is in progress."
    exit 1
fi
trap "rm -f $LOCKFILE" EXIT
touch "$LOCKFILE"

DATE=$(date +"%Y-%m-%d_%H-%M-%S")
MOUNTED_BY_SCRIPT=false

echo "=== Nextcloud Backup Started at $DATE ==="

# === DETECT AND MOUNT BACKUP PARTITION BY LABEL ===
echo "[*] Detecting backup partition with label '$BACKUP_LABEL'..."
BACKUP_PARTITION=$(lsblk -o NAME,LABEL -nr | awk -v label="$BACKUP_LABEL" '$2 == label {print "/dev/"$1}')

if [ -z "$BACKUP_PARTITION" ]; then
    echo "[!] No partition with label '$BACKUP_LABEL' found. Aborting."
    exit 1
fi
echo "[*] Found backup partition: $BACKUP_PARTITION"

mkdir -p "$MOUNT_POINT"
if mountpoint -q "$MOUNT_POINT"; then
    echo "[*] $MOUNT_POINT is already mounted."
else
    echo "[*] Mounting partition with label $BACKUP_LABEL at $MOUNT_POINT..."
    mount -L "$BACKUP_LABEL" "$MOUNT_POINT" || {
        echo "[!] Failed to mount partition $BACKUP_LABEL. Exiting."
        exit 1
    }
    MOUNTED_BY_SCRIPT=true
fi

# === DYNAMIC DISK SPACE CHECK ===
echo "[*] Estimating backup size..."
ESTIMATED_DATA_KB=$(du -sk "$DATA_DIR" | awk '{print $1}')
# Add 10% for DB + overhead
ESTIMATED_TOTAL_KB=$((ESTIMATED_DATA_KB + ESTIMATED_DATA_KB / 10))

check_space_and_cleanup() {
    AVAILABLE_KB=$(df --output=avail "$MOUNT_POINT" | tail -n1)
    echo "[*] Available space: $((AVAILABLE_KB / 1024)) MB, Needed: $((ESTIMATED_TOTAL_KB / 1024)) MB"
    
    if [ "$AVAILABLE_KB" -lt "$ESTIMATED_TOTAL_KB" ]; then
        echo "[!] Not enough free space for backup."
        
        OLDEST_BACKUP=$(find "$MOUNT_POINT" -maxdepth 1 -type d -name "nextcloud_backup_*" | sort | head -n 1)
        BACKUP_COUNT=$(find "$MOUNT_POINT" -maxdepth 1 -type d -name "nextcloud_backup_*" | wc -l)
        
        if [ "$BACKUP_COUNT" -gt 1 ] && [ -n "$OLDEST_BACKUP" ]; then
            echo "[*] Removing oldest backup: $OLDEST_BACKUP"
            rm -rf "$OLDEST_BACKUP"
            echo "[*] Retrying space check..."
            check_space_and_cleanup
        else
            echo "[!] Only one or no backups exist. Cannot delete further. Aborting."
            $MOUNTED_BY_SCRIPT && umount "$MOUNT_POINT"
            exit 1
        fi
    fi
}
check_space_and_cleanup

# === PREP TEMP BACKUP DIR ===
TEMP_DIR="$MOUNT_POINT/.incomplete_backup_$DATE"
BACKUP_DIR="$MOUNT_POINT/nextcloud_backup_$DATE"
mkdir -p "$TEMP_DIR"

# === ENABLE NEXTCLOUD MAINTENANCE MODE ===
echo "[*] Enabling Nextcloud maintenance mode..."
docker exec -u www-data "$NEXTCLOUD_CONTAINER" php occ maintenance:mode --on

# === BACKUP DATA DIR ===
echo "[*] Backing up Nextcloud data directory..."
rsync -a --info=progress2 --delete "$DATA_DIR/" "$TEMP_DIR/data/"

# === BACKUP DATABASE ===
echo "[*] Backing up Nextcloud database..."
docker run --rm \
  --network container:"$DB_CONTAINER" \
  -e MYSQL_PWD="$DB_PASS" \
  mysql:8 \
  mysqldump --column-statistics=0 -h 127.0.0.1 -u "$DB_USER" "$DB_NAME" \
  | gzip > "$TEMP_DIR/nextcloud_db_$DATE.sql.gz"

# === VERIFY DB DUMP ===
if [ ! -s "$TEMP_DIR/nextcloud_db_$DATE.sql.gz" ]; then
    echo "[!] Database dump is empty. Aborting."
    docker exec -u www-data "$NEXTCLOUD_CONTAINER" php occ maintenance:mode --off
    $MOUNTED_BY_SCRIPT && umount "$MOUNT_POINT"
    exit 1
fi

# === DISABLE MAINTENANCE MODE ASAP ===
echo "[*] Disabling Nextcloud maintenance mode..."
docker exec -u www-data "$NEXTCLOUD_CONTAINER" php occ maintenance:mode --off

# === FINALIZE BACKUP ===
echo "[*] Compressing backup..."
mkdir -p "$BACKUP_DIR"
tar -czf "$BACKUP_DIR/nextcloud-backup-$DATE.tar.gz" -C "$TEMP_DIR" .

# Remove temp dir
rm -rf "$TEMP_DIR"

# === PRUNE OLD BACKUPS (Extra cleanup) ===
echo "[*] Deleting backups older than $KEEP_DAYS days..."
find "$MOUNT_POINT" -maxdepth 1 -type d -name "nextcloud_backup_*" -mtime +$KEEP_DAYS -exec rm -rf {} \;

# === UNMOUNT BACKUP DRIVE IF WE MOUNTED IT ===
if $MOUNTED_BY_SCRIPT; then
    echo "[*] Unmounting backup drive..."
    umount "$MOUNT_POINT"
fi

echo "[✓] Backup completed successfully: $BACKUP_DIR"
echo "=== Nextcloud Backup Finished at $(date +"%Y-%m-%d_%H-%M-%S") ==="
