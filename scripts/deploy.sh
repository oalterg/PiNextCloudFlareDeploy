#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/common.sh"
SETUP_LOG_FILE="$LOG_DIR/main_setup.log"

if [ -t 1 ]; then :; else exec >> "$SETUP_LOG_FILE" 2>&1; fi

log_info "=== Starting Deployment/Update: $(date) ==="
load_env

# --- 0. Install Dependencies ---
log_info "Installing dependencies"
apt-get install -y ca-certificates gnupg lsb-release cron jq moreutils gpg rsync initramfs-tools
# Docker setup (idempotent)
if ! [ -f /etc/apt/keyrings/docker.gpg ]; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y
fi
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

# --- 1. Docker Stack Deployment ---
log_info "Deploying Docker stack, this can take while..."
# Ensure docker is running (if just installed)
if ! systemctl is-active --quiet docker; then
    echo "Waiting for Docker service..."
    systemctl start docker
    sleep 5
fi

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull
profiles=$(get_tunnel_profiles)
log_info "Tunnel Profile: $profiles"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ${profiles} up -d --remove-orphans

wait_for_healthy "db" 120 || die "DB failed to start."
wait_for_healthy "nextcloud" 400 || die "Nextcloud failed to start."
wait_for_healthy "homeassistant" 120 || die "Homeassistant failed to start." 


# --- 2. Post-Deploy Proxy Configuration ---
log_info "Applying Nextcloud and Homeassistant Proxy Settings..."
NC_CID=$(get_nc_cid)

# Wait for NC internal install
log_info "Waiting for Nextcloud installation to complete..."
TIMEOUT=120
while [[ $TIMEOUT -gt 0 ]]; do
    if docker exec -u www-data "$NC_CID" php occ status | grep -q "installed: true"; then
        break
    fi
    sleep 5
    ((TIMEOUT-=5))
done
[[ $TIMEOUT -le 0 ]] && die "Nextcloud installation timed out."

configure_nc_ha_proxy_settings || die "Proxy configuration failed."
docker compose -f "$COMPOSE_FILE" restart nextcloud homeassistant
wait_for_healthy "nextcloud" 120 || die "Nextcloud failed to get healthy after proxy config" 
wait_for_healthy "homeassistant" 120 || die "Homeassistant failed to get healthy after proxy config" 

# --- 3. Cron Setup ---
log_info "Configuring Cron..."
docker exec -u www-data "$NC_CID" php occ background:cron || true
echo "*/5 * * * * root docker exec -u www-data \$(docker compose -f $COMPOSE_FILE ps -q nextcloud) php cron.php" > /etc/cron.d/nextcloud-cron
chmod 644 /etc/cron.d/nextcloud-cron

# --- 4. Hardening ---
# Disable wireless for power efficiency
log_info "Disabling Wireless interfaces..."
rfkill block wifi || true
rfkill block bluetooth || true

log_info "=== Deployment Complete ==="
touch "$REPO_DIR/.setup_complete"
