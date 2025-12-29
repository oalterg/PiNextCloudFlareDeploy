#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/common.sh"
SETUP_LOG_FILE="$LOG_DIR/main_setup.log"

if [ -t 1 ]; then :; else exec >> "$SETUP_LOG_FILE" 2>&1; fi

log_info "=== Starting Deployment: $(date) ==="

load_env

# --- 0. Install Dependencies ---
log_info "Installing dependencies"
# Added -qq for quieter output in logs
apt-get install -y -qq ca-certificates gnupg lsb-release cron jq moreutils gpg rsync initramfs-tools

# Docker setup (idempotent)
if ! [ -f /etc/apt/keyrings/docker.gpg ]; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y -qq
fi

apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

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
log_info "Starting Stack with Tunnel Profile: ${profiles:-None}"
docker compose --env-file "$ENV_FILE" $(get_compose_args) ${profiles} up -d --remove-orphans

# 1d. Verification
wait_for_healthy "nextcloud" 400 || die "Nextcloud failed to start."
wait_for_healthy "homeassistant" 120 || die "Homeassistant failed to start." 

# 1e. Create Home Assistant Admin Account
log_info "Hardening Home Assistant Admin account..."
create_ha_admin "$MASTER_PASSWORD" || echo "Fallback: Proceed with manual HA account creation."

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

# Restart to apply proxy settings (Safe restart)
# We do not restart DB here, only the frontends
docker compose $(get_compose_args) restart nextcloud homeassistant

wait_for_healthy "nextcloud" 120 || die "Nextcloud failed to get healthy after proxy config" 
wait_for_healthy "homeassistant" 120 || die "Homeassistant failed to get healthy after proxy config" 

# --- 3. Cron Setup ---
log_info "Configuring Cron..."
docker exec -u www-data "$NC_CID" php occ background:cron || true
# Use atomic write for cron file
echo "*/5 * * * * root docker exec -u www-data \$(docker compose -f $COMPOSE_FILE ps -q nextcloud) php cron.php" > /etc/cron.d/nextcloud-cron
chmod 644 /etc/cron.d/nextcloud-cron
service cron reload || log_error "Nextcloud cronjob reloading failed."

# --- 4. Hardening ---
log_info "Disabling Wireless interfaces..."
rfkill block wifi || log_error "WiFi could not be disabled."
rfkill block bluetooth || log_error "Bluetooth could not be disabled."

log_info "=== Deployment Complete ==="
# Signal specifically for the UI to pick up
echo "Deployment Complete - Ready for Handover"
touch "$INSTALL_DIR/.setup_complete"
