#!/bin/bash
set -euo pipefail

# --- Configuration ---
REPO_OWNER="oalterg"
REPO_NAME="PiNextCloudFlareDeploy"
INSTALL_DIR="/opt/raspi-nextcloud-setup"
APP_DIR="/opt/appliance-manager"
BACKUP_DIR="/var/backups/raspi-manager"
LOG_FILE="/var/log/raspi-nextcloud/manager_update.log"

# Redirect all output to log file and echo to stdout
exec > >(tee -a "$LOG_FILE") 2>&1

echo "========================================"
echo "Update Started: $(date)"
echo "Channel: ${1:-stable} | Target: ${2:-main}"

# Arguments: $1 = Channel (stable/beta), $2 = Target Ref
CHANNEL="${1:-stable}"
TARGET_REF="${2:-main}"

# 1. Prepare Environment
mkdir -p "$BACKUP_DIR"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# 2. Download Artifact
if [ "$CHANNEL" == "stable" ]; then
    URL="https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/tags/$TARGET_REF.tar.gz"
else
    URL="https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/main.tar.gz"
fi

echo "[INFO] Downloading from $URL..."
curl -L -f -s "$URL" -o "$TEMP_DIR/update.tar.gz" || { echo "[ERROR] Download failed"; exit 1; }

# 3. Extract
echo "[INFO] Extracting..."
mkdir -p "$TEMP_DIR/extract"
tar -xzf "$TEMP_DIR/update.tar.gz" --strip-components=1 -C "$TEMP_DIR/extract"

# 4. Backup Critical Configs (Preserve State)
echo "[INFO] Preserving configuration..."
cp "$INSTALL_DIR/.env" "$TEMP_DIR/extract/.env" 2>/dev/null || echo "[WARN] .env not found, skipping preservation"
cp "$INSTALL_DIR/docker-compose.override.yml" "$TEMP_DIR/extract/docker-compose.override.yml" 2>/dev/null || true
cp "$INSTALL_DIR/factory_config.txt" "$TEMP_DIR/extract/factory_config.txt" 2>/dev/null || true

# 5. Atomic File Sync
echo "[INFO] Applying file updates..."
# rsync ensures we get new files, delete removed files, but exclude our preserved configs from being overwritten if they were missing in source
rsync -a --delete \
    --exclude='.env' \
    --exclude='docker-compose.override.yml' \
    --exclude='.git' \
    --exclude='version.json' \
    "$TEMP_DIR/extract/" "$INSTALL_DIR/"

# 6. Deploy Web Manager Files
echo "[INFO] Deploying Web App..."
mkdir -p "$APP_DIR/templates"
cp "$INSTALL_DIR/src/app.py" "$APP_DIR/"
cp -r "$INSTALL_DIR/src/templates/"* "$APP_DIR/templates/"

# 7. Update Binaries
chmod +x "$INSTALL_DIR/raspi-cloud"
ln -sf "$INSTALL_DIR/raspi-cloud" "/usr/local/sbin/raspi-cloud"

# 8. Dependency Management
echo "[INFO] Updating Python dependencies..."
if [ -f "$INSTALL_DIR/requirements.txt" ]; then
    pip3 install -r "$INSTALL_DIR/requirements.txt" --break-system-packages
fi

# 9. Docker Stack Update (Hardening Request #3)
echo "[INFO] Updating Docker Stack..."
cd "$INSTALL_DIR"
# Pull latest images defined in compose
docker compose pull
# Restart containers (recreates them if image changed or compose file changed)
docker compose up -d --remove-orphans

# 10. Write Version File
cat > "$INSTALL_DIR/version.json" <<EOF
{
  "channel": "$CHANNEL",
  "ref": "$TARGET_REF",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

echo "[INFO] Restarting Manager Service..."
systemctl restart appliance-manager

echo "[SUCCESS] Update Complete."