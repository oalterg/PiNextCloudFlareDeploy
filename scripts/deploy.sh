#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/common.sh"
SETUP_LOG_FILE="$LOG_DIR/main_setup.log"

if [ -t 1 ]; then :; else exec >> "$SETUP_LOG_FILE" 2>&1; fi

log_info "=== Starting Deployment: $(date) ==="

load_env

# --- 0. Ensure dependencies installed ---
install_deps_enable_docker

# --- 1. Docker Stack Deployment ---
log_info "Deploying Docker stack, this can take while..."
# Ensure docker is running
if ! systemctl is-active --quiet docker; then
    echo "Waiting for Docker service..."
    systemctl start docker
    sleep 5
fi

# 1a. Pull Images
docker compose --env-file "$ENV_FILE" $(get_compose_args) pull

# 1b. Start Database FIRST (Fix for 'Not Installed' race condition)
log_info "Starting Database..."
docker compose --env-file "$ENV_FILE" $(get_compose_args) up -d --remove-orphans db
wait_for_healthy "db" 120 || die "DB failed to start. Aborting deployment."

# 1c. Start Remaining Services
profiles=$(get_tunnel_profiles)

# If this is the initial setup (creds not claimed), do NOT start tunnels.
# This prevents internet exposure before the admin password is claimed by the user.
if [ -f "$INSTALL_DIR/install_creds.json" ]; then
    log_info "Initial setup detected. Skipping tunnel startup for security."
    profiles=""
fi

log_info "Starting Stack with Tunnel Profile: ${profiles:-None}"
docker compose --env-file "$ENV_FILE" $(get_compose_args) ${profiles} up -d --remove-orphans

# 1d. Verification
wait_for_healthy "nextcloud" 400 || die "Nextcloud failed to start."
wait_for_healthy "homeassistant" 120 || die "Homeassistant failed to start." 

# 1e. Create Home Assistant Admin Account
log_info "Hardening Home Assistant Admin account..."
bash "$SCRIPT_DIR/utilities.sh" ha_admin "$MASTER_PASSWORD" || log_error "HA Admin creation failed."

# --- 2. Post-Deploy Proxy Configuration ---
log_info "Applying Nextcloud and Homeassistant Proxy Settings..."
NC_CID=$(get_nc_cid)

# Wait for NC internal install to be verified
log_info "Waiting for Nextcloud installation status to confirm 'true'..."
TIMEOUT=120
while [[ $TIMEOUT -gt 0 ]]; do
    # Suppress stderr to avoid flooding log with 'not installed' errors while waiting
    if docker exec -u www-data "$NC_CID" php occ status 2>/dev/null | grep -q "installed: true"; then
        log_info "Nextcloud installation verified."
        break
    fi
    # If the DB is up but NC is stuck, the split startup above usually fixes it.
    # But if we are here, we log a heartbeat.
    if (( TIMEOUT % 10 == 0 )); then
        log_info "Still waiting for Nextcloud ($TIMEOUT seconds remaining)..."
    fi
    sleep 5
    ((TIMEOUT-=5))
done

[[ $TIMEOUT -le 0 ]] && die "Nextcloud installation timed out. Check if the database password in .env matches the volume data."

configure_nc_ha_proxy_settings || die "Proxy configuration failed."

log_info "Applying Nextcloud Redis Configuration..."
configure_nextcloud_redis || log_warn "Redis configuration failed (non-fatal)."

# Restart to apply proxy settings (Safe restart)
# We do not restart DB here, only the frontends
docker compose $(get_compose_args) restart nextcloud homeassistant

wait_for_healthy "nextcloud" 120 || die "Nextcloud failed to get healthy after proxy config" 
wait_for_healthy "homeassistant" 120 || die "Homeassistant failed to get healthy after proxy config" 

# --- 3. Cron Setup ---
log_info "Configuring Cron..."
# Use the utility script to ensure consistency and use systemctl
bash "$SCRIPT_DIR/utilities.sh" cron || log_error "Nextcloud cron configuration failed."

# --- 4. Hardening ---
log_info "Disabling Wireless interfaces..."

if command -v rfkill >/dev/null 2>&1; then
    log_info "Disabling Wireless interfaces..."
    rfkill block wifi || log_warn "WiFi could not be disabled (possibly already disabled or unavailable)."
    rfkill block bluetooth || log_warn "Bluetooth could not be disabled (possibly already disabled or unavailable)."
else
    log_warn "rfkill command not found. Wireless interfaces not disabled."
fi

log_info "=== Deployment Complete ==="

# Ensure permissions on creds file so app.py can read it
if [ -f "$INSTALL_DIR/install_creds.json" ]; then
    # Ensure ownership is root:root so the service can read it
    chown root:root "$INSTALL_DIR/install_creds.json"
    chmod 644 "$INSTALL_DIR/install_creds.json"
fi

# Mark setup as complete before signaling the UI
touch "$INSTALL_DIR/.setup_complete"

# Signal specifically for the UI to pick up
echo "Deployment Complete - Ready for Handover"
