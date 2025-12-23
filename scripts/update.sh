#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/common.sh"

# --- Configuration ---
REPO_OWNER="oalterg"
REPO_NAME="HomeBrain"
INSTALL_DIR="/opt/homebrain"
LOG_FILE="/var/log/homebrain/manager_update.log"
ENV_FILE="$INSTALL_DIR/.env"

if [ -t 1 ]; then :; else exec >> "$LOG_FILE" 2>&1; fi

log_info "========================================"
log_info "Update Started: $(date)"
log_info "Channel: ${1:-stable} | Target: ${2:-main}"

# Arguments: $1 = Channel (stable/beta), $2 = Target Ref
CHANNEL="${1:-stable}"
TARGET_REF="${2:-main}"

# 0. Self-Update Check (Hardening)
# Fetch the target update.sh and common.sh, reload if either changed
log_info "Checking for update script changes..."

SELF_TMP_DIR=$(mktemp -d)
trap 'rm -rf "$SELF_TMP_DIR"' EXIT  # Ensure cleanup on exit

if [ "$CHANNEL" == "stable" ]; then
    BASE_URL="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$TARGET_REF/scripts"
else
    BASE_URL="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/main/scripts"
fi

# Hardened curl: timeout, retries, fail on error
curl -L -f -s --max-time 30 --retry 3 --retry-delay 5 "$BASE_URL/update.sh" -o "$SELF_TMP_DIR/update.sh" || { log_error "Failed to fetch new update script"; exit 1; }
curl -L -f -s --max-time 30 --retry 3 --retry-delay 5 "$BASE_URL/common.sh" -o "$SELF_TMP_DIR/common.sh" || { log_error "Failed to fetch new common script"; exit 1; }

chmod +x "$SELF_TMP_DIR/update.sh"

CURRENT_UPDATE="$SCRIPT_DIR/update.sh"
CURRENT_COMMON="$SCRIPT_DIR/common.sh"

if ! cmp -s "$CURRENT_UPDATE" "$SELF_TMP_DIR/update.sh" || ! cmp -s "$CURRENT_COMMON" "$SELF_TMP_DIR/common.sh" ; then
    log_info "Changes detected in update.sh or common.sh. Reloading with new versions..."
    exec "$SELF_TMP_DIR/update.sh" "$CHANNEL" "$TARGET_REF"
fi

log_info "Update script and common up-to-date. Proceeding..."

load_env

# 1. Prepare Environment
mkdir -p "/tmp" # Ensure tmp exists
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR" "$SELF_TMP_DIR"' EXIT  # Double-trap for safety

# 2. Download Artifact
if [ "$CHANNEL" == "stable" ]; then
    URL="https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/tags/$TARGET_REF.tar.gz"
else
    URL="https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/main.tar.gz"
fi

log_info "Downloading from $URL..."
curl -L -f -s --max-time 60 --retry 3 --retry-delay 5 "$URL" -o "$TEMP_DIR/update.tar.gz" || { log_error "Download failed"; exit 1; }

# Todo: Add checksum verification

# 3. Extract
log_info "Extracting..."
mkdir -p "$TEMP_DIR/extract"
tar -xzf "$TEMP_DIR/update.tar.gz" --strip-components=1 -C "$TEMP_DIR/extract" || { log_error "Extraction failed"; exit 1; }

# 5. Atomic File Sync
log_info "Applying file updates, preserving configuration..."
# rsync ensures we get new files, delete removed files, but exclude our preserved configs from being overwritten if they were missing in source
rsync -a --delete \
--exclude='.env' \
--exclude='.setup_complete' \
--exclude='config/docker-compose.override.yml' \
--exclude='docker-compose.override.yml' \
--exclude='.git' \
--exclude='version.json' \
"$TEMP_DIR/extract/" "$INSTALL_DIR/" || { log_error "Rsync failed"; exit 1; }

# 7. Update Binaries
chmod +x "$INSTALL_DIR/scripts/raspi-cloud"
ln -sf "$INSTALL_DIR/scripts/raspi-cloud" "/usr/local/sbin/raspi-cloud" || { log_error "Failed to link raspi-cloud"; exit 1; }

# 8. Dependency Management
log_info "Updating Python dependencies..."
if [ -f "$INSTALL_DIR/requirements.txt" ]; then
    pip3 install -r "$INSTALL_DIR/requirements.txt" --break-system-packages || { log_error "Pip install failed"; exit 1; }
fi

# 9. Docker Stack Update
log_info "Updating Docker Stack..."
cd "${INSTALL_DIR}" || die "Failed to cd to ${INSTALL_DIR}"
# Pull latest images defined in compose
docker compose --env-file "$ENV_FILE" $(get_compose_args) pull || { log_error "Docker pull failed"; exit 1; }
# Restart containers (recreates them if image changed or compose file changed)
profiles=$(get_tunnel_profiles)
docker compose --env-file "$ENV_FILE" $(get_compose_args) ${profiles} up -d --remove-orphans || { log_error "Docker up failed"; exit 1; }

# 10. Write Version File
cat > "$INSTALL_DIR/version.json" <<EOF
{
  "channel": "$CHANNEL",
  "ref": "$TARGET_REF",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

log_info "Restarting Manager Service..."
systemctl restart homebrain-manager || { log_error "Service restart failed"; exit 1; }
