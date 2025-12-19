#!/bin/bash

# --- Global Configuration ---
export INSTALL_DIR="/opt/homebrain"
export LOG_DIR="/var/log/homebrain"
export ENV_FILE="$INSTALL_DIR/.env"
export COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
export OVERRIDE_FILE="$INSTALL_DIR/docker-compose.override.yml"
export BACKUP_MOUNTDIR="/mnt/backup"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# --- Logging Helpers ---
log_info() { echo "[INFO] $1" >&2; }
log_warn() { echo "[WARN] $1" >&2; }
log_error() { echo "[ERROR] $1" >&2; }
die() { log_error "$1" >&2; exit 1; }

# --- Environment Loading ---
load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        source "$ENV_FILE"
        set +a
    else
        die "Environment file ($ENV_FILE) not found."
    fi
}

# --- Docker Helpers ---
# Helper to get all active compose files
get_compose_args() {
    local args="-f $COMPOSE_FILE"
    if [[ -f "$OVERRIDE_FILE" ]]; then
        args="$args -f $OVERRIDE_FILE"
    fi
    echo "$args"
}

get_nc_cid() {
    docker compose $(get_compose_args) ps -q nextcloud 2>/dev/null || true
}

get_ha_cid() {
    docker compose $(get_compose_args) ps -q homeassistant 2>/dev/null || true
}

is_stack_running() {
    [[ -n "$(get_nc_cid)" ]]
}

# --- Tunnel Profiles Helper ---
get_tunnel_profiles() {
    local profiles=""
    # 1. Sanitize Inputs (Trim Whitespace) to prevent false positives
    local p_endpoint="${PANGOLIN_ENDPOINT:-}"; p_endpoint="${p_endpoint//[[:space:]]/}"
    local p_id="${NEWT_ID:-}"; p_id="${p_id//[[:space:]]/}"
    local p_secret="${NEWT_SECRET:-}"; p_secret="${p_secret//[[:space:]]/}"

    local cf_nc_token="${CF_TOKEN_NC:-}"; cf_nc_token="${cf_nc_token//[[:space:]]/}"
    local cf_ha_token="${CF_TOKEN_HA:-}"; cf_ha_token="${cf_ha_token//[[:space:]]/}"

    # 2. Determine Mode (custom Cloudflare prioritized over Pangolin)
    # We enforce mutual exclusivity: If Cloudflare tokens are provided, we ignore Pangolin tokens.

    if [[ -n "$cf_nc_token" ]] || [[ -n "$cf_ha_token" ]]; then
        # --- Cloudflare Mode ---
        if [[ -n "$cf_nc_token" ]]; then
            profiles="${profiles} --profile cloudflare-nc"
        fi
        if [[ -n "$cf_ha_token" ]]; then
            profiles="${profiles} --profile cloudflare-ha"
        fi
    elif [[ -n "$p_endpoint" ]] && [[ -n "$p_id" ]] && [[ -n "$p_secret" ]]; then
        # --- Pangolin Mode ---
        profiles="--profile pangolin"
    else
        die "No complete tunnel configuration found. Deploying local-only."
    fi

    # Trim leading space if any
    profiles="${profiles#" "}"

    echo "${profiles}"
}

wait_for_healthy() {
    local service_name="$1"
    local timeout_seconds="$2"
    local container_id

    log_info "Waiting for $service_name to become healthy..."
    
    # Retry finding container ID
    local retries=10
    while [[ $retries -gt 0 ]]; do
        container_id=$(docker compose $(get_compose_args) ps -q "$service_name" 2>/dev/null)
        if [[ -n "$container_id" ]]; then break; fi
        sleep 2
        ((retries--))
    done

    [[ -z "$container_id" ]] && return 1

    local end_time=$((SECONDS + timeout_seconds))
    while [ $SECONDS -lt $end_time ]; do
        local status
        status=$(docker inspect --format="{{if .State.Health}}{{.State.Health.Status}}{{end}}" "$container_id" 2>/dev/null || echo "unknown")
        if [ "$status" == "healthy" ]; then
            log_info "✅ $service_name is healthy."
            return 0
        fi
        sleep 3
    done
    log_error "❌ $service_name failed health check."
    return 1
}

# --- Maintenance Mode ---
set_maintenance_mode() {
    local mode="$1" # --on or --off
    local nc_cid
    nc_cid=$(get_nc_cid)
    
    if [[ -z "$nc_cid" ]]; then return 1; fi
    
    log_info "Setting maintenance mode: $mode"
    docker exec -u www-data "$nc_cid" php occ maintenance:mode "$mode" || true
}

# Configures Trusted Proxies in Home Assistant configuration.yaml
configure_ha_proxy_settings() {
    local subnet="$1"
    local cid="$2"

    log_info "Configuring Home Assistant trusted proxies for subnet: $subnet"

    docker exec "$cid" sh -c "
        CONF='/config/configuration.yaml'
        # 1. Check if the subnet is already trusted
        if grep -Fq '$subnet' \"\$CONF\"; then
            echo 'Subnet already trusted.'
        else
            # 2. Check if trusted_proxies block exists
            if grep -q 'trusted_proxies:' \"\$CONF\"; then
                # Append to existing list
                sed -i '/trusted_proxies:/a \    - $subnet' \"\$CONF\"
            # 3. Check if http block exists but no proxies
            elif grep -q '^http:' \"\$CONF\"; then
                sed -i '/^http:/a \  use_x_forwarded_for: true\n  trusted_proxies:\n    - $subnet' \"\$CONF\"
            # 4. No http block at all
            else
                echo '
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - $subnet
' >> \"\$CONF\"
            fi
        fi
    "
}

configure_nc_ha_proxy_settings() {
    log_info "Configuring trusted proxies for Docker Subnet..."
    local nc_cid=$(get_nc_cid)
    local ha_cid=$(get_ha_cid)
    
    # Get Docker Bridge Subnet
    local subnet
    # Try to find the network used by nextcloud
    if [[ -n "$nc_cid" ]]; then
        local net_name=$(docker inspect "$nc_cid" --format='{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
        if [[ -n "$net_name" ]]; then
            subnet=$(docker network inspect "$net_name" --format='{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)
        fi
    fi
    
    # Fallback default if detection fails
    if [[ -z "$subnet" ]]; then
        subnet="172.16.0.0/12"
    fi
    log_info "Detected Docker Subnet: $subnet"

    # 1. Update Nextcloud Trusted Proxies
    if [[ -n "$nc_cid" ]]; then
        # Nextcloud HTTPS & Proxy Config
        docker exec --user www-data "$nc_cid" php occ config:system:set overwriteprotocol --value=https || die "Failed to set overwriteprotocol."
        docker exec --user www-data "$nc_cid" php occ config:system:set trusted_proxies 0 --value="$TRUSTED_PROXIES_0" || die "Failed to set trusted_proxies 0."
        docker exec --user www-data "$nc_cid" php occ config:system:set trusted_proxies 1 --value="$TRUSTED_PROXIES_1" || die "Failed to set trusted_proxies 1."
        docker exec --user www-data "$nc_cid" php occ config:system:set trusted_domains 1 --value="$NEXTCLOUD_TRUSTED_DOMAINS" || die "Failed to set trusted_domains 1."
        # Use index 10 to avoid conflict with existing static ones
        docker exec -u www-data "$nc_cid" php occ config:system:set trusted_proxies 10 --value="$subnet" || die "Failed to set trusted_proxies 10."
        # Also ensure localhost is trusted
        docker exec -u www-data "$nc_cid" php occ config:system:set trusted_proxies 11 --value="127.0.0.1" || die "Failed to set trusted_proxies 11."
    fi

    # 2. Update Home Assistant Trusted Proxies
    if [[ -n "$ha_cid" ]]; then
        configure_ha_proxy_settings "$subnet" "$ha_cid"
    fi
}