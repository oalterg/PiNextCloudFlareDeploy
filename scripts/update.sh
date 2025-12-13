#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/common.sh"

# --- Configuration ---
REPO_OWNER="oalterg"
REPO_NAME="PiNextCloudFlareDeploy"
INSTALL_DIR="/opt/raspi-nextcloud-setup"
APP_DIR="/opt/appliance-manager"
BACKUP_DIR="/var/backups/raspi-manager"
LOG_FILE="/var/log/raspi-nextcloud/manager_update.log"
ENV_FILE="$INSTALL_DIR/.env"

if [ -t 1 ]; then :; else exec >> "$LOG_FILE" 2>&1; fi

log_info "========================================"
log_info "Update Started: $(date)"
log_info "Channel: ${1:-stable} | Target: ${2:-main}"

# Arguments: $1 = Channel (stable/beta), $2 = Target Ref
CHANNEL="${1:-stable}"
TARGET_REF="${2:-main}"

load_env

# 0. Self-Update Check (Hardening)
# Fetch the target update.sh and reload if changed
# 1. Prepare Environment
mkdir -p "/tmp"  # Ensure tmp exists
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

log_info "Checking for update script changes..."
NEW_UPDATE="$TEMP_DIR/new_update.sh"
if [ "$CHANNEL" == "stable" ]; then
    RAW_URL="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$TARGET_REF/scripts/update.sh"
else
    RAW_URL="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/main/scripts/update.sh"
fi
curl -L -f -s "$RAW_URL" -o "$NEW_UPDATE" || { log_error "Failed to fetch new update script"; exit 1; }
chmod +x "$NEW_UPDATE"

CURRENT_SCRIPT="${BASH_SOURCE[0]}"
if ! cmp -s "$CURRENT_SCRIPT" "$NEW_UPDATE"; then
    log_info "New update script detected. Reloading..."
    exec "$NEW_UPDATE" "$CHANNEL" "$TARGET_REF"
fi
log_info "Update script up-to-date. Proceeding..."

# 2. Download Artifact
if [ "$CHANNEL" == "stable" ]; then
    URL="https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/tags/$TARGET_REF.tar.gz"
else
    URL="https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/main.tar.gz"
fi

log_info "Downloading from $URL..."
curl -L -f -s "$URL" -o "$TEMP_DIR/update.tar.gz" || { log_error "Download failed"; exit 1; }

# 3. Extract
log_info "Extracting..."
mkdir -p "$TEMP_DIR/extract"
tar -xzf "$TEMP_DIR/update.tar.gz" --strip-components=1 -C "$TEMP_DIR/extract"

# 4. Backup Critical Configs (Preserve State)
log_info "Preserving configuration..."
cp "$INSTALL_DIR/.env" "$TEMP_DIR/extract/.env" 2>/dev/null || log_warn ".env not found, skipping preservation"
cp "$INSTALL_DIR/docker-compose.override.yml" "$TEMP_DIR/extract/docker-compose.override.yml" 2>/dev/null || true
cp "$INSTALL_DIR/factory_config.txt" "$TEMP_DIR/extract/factory_config.txt" 2>/dev/null || true

# 5. Atomic File Sync
log_info "Applying file updates..."
# rsync ensures we get new files, delete removed files, but exclude our preserved configs from being overwritten if they were missing in source
rsync -a --delete \
    --exclude='.env' \
    --exclude='.setup_complete' \
    --exclude='docker-compose.yml' \
    --exclude='docker-compose.override.yml' \
    --exclude='.git' \
    --exclude='version.json' \
    "$TEMP_DIR/extract/" "$INSTALL_DIR/"

# 6. Deploy Web Manager Files
log_info "Deploying Web App..."
mkdir -p "$APP_DIR/templates"
cp "$INSTALL_DIR/src/app.py" "$APP_DIR/"
cp -r "$INSTALL_DIR/src/templates/"* "$APP_DIR/templates/"

# 7. Update Binaries
chmod +x "$INSTALL_DIR/scripts/raspi-cloud"
ln -sf "$INSTALL_DIR/scripts/raspi-cloud" "/usr/local/sbin/raspi-cloud"

# 8. Dependency Management
log_info "Updating Python dependencies..."
if [ -f "$INSTALL_DIR/requirements.txt" ]; then
    pip3 install -r "$INSTALL_DIR/requirements.txt" --break-system-packages
fi

# 9. Docker Stack Update
log_info "Updating Docker Stack..."
cd "${INSTALL_DIR}" || die "Failed to cd to ${INSTALL_DIR}"
# Pull latest images defined in compose
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull 
# Restart containers (recreates them if image changed or compose file changed)
profiles=$(get_tunnel_profiles)
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ${profiles} up -d --remove-orphans

# 10. Write Version File
cat > "$INSTALL_DIR/version.json" <<EOF
{
  "channel": "$CHANNEL",
  "ref": "$TARGET_REF",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

log_info "Restarting Manager Service..."
systemctl restart appliance-manager
