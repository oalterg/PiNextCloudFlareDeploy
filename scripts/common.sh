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

# --- Configuration Helpers ---
update_env_var() {
    local key="$1"
    local value="$2"
    
    if [[ -f "$ENV_FILE" ]]; then
        # If key exists, replace it
        if grep -q "^${key}=" "$ENV_FILE"; then
            # Escape value for sed (basic safety for URLs/domains)
            local safe_val
            safe_val=$(printf '%s\n' "$value" | sed -e 's/[\/&]/\\&/g')
            sed -i "s|^${key}=.*|${key}=${safe_val}|" "$ENV_FILE"
        else
            # If key missing, append it
            echo "${key}=${value}" >> "$ENV_FILE"
        fi
    else
        log_warn ".env file not found, creating new one."
        echo "${key}=${value}" > "$ENV_FILE"
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
    docker compose $(get_compose_args) ps -a -q nextcloud 2>/dev/null || true
}

get_ha_cid() {
    docker compose $(get_compose_args) ps -a -q homeassistant 2>/dev/null || true
}

get_nc_db_cid() {
    docker compose $(get_compose_args) ps -a -q db 2>/dev/null || true
}

is_stack_running() {
    local nc_cid=$(get_nc_cid)
    local ha_cid=$(get_ha_cid)
    # Returns true only if both Nextcloud and Home Assistant container IDs are found and are running
    [[ -n "$nc_cid" ]] && [[ $(docker inspect -f '{{.State.Running}}' "$nc_cid" 2>/dev/null) == "true" ]] && \
    [[ -n "$ha_cid" ]] && [[ $(docker inspect -f '{{.State.Running}}' "$ha_cid" 2>/dev/null) == "true" ]]
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

install_deps_enable_docker() {
    # --- 0. Install Dependencies ---
    log_info "Installing dependencies"
    # Added -qq for quieter output in logs
    apt-get install -y -qq ca-certificates gnupg lsb-release cron gpg rsync initramfs-tools python3-flask python3-dotenv python3-requests python3-pip jq moreutils pwgen git parted
    apt-get update -qq

    # Docker setup
    if ! [ -f /etc/apt/keyrings/docker.gpg ]; then
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
        apt-get update -y -qq
    fi
    
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    log_info "Starting docker service"
    systemctl enable --now docker
}

# --- Maintenance Mode ---
set_maintenance_mode() {
    local mode="$1" # --on or --off
    local nc_cid
    nc_cid=$(get_nc_cid)
    
    if [[ -z "$nc_cid" ]]; then return 1; fi
    
    log_info "Setting Nextcloud maintenance mode: $mode"
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
        docker exec --user www-data "$nc_cid" php occ config:system:set trusted_proxies 10 --value="$subnet" || die "Failed to set trusted_proxies 10."
        # Also ensure localhost is trusted
        docker exec --user www-data "$nc_cid" php occ config:system:set trusted_proxies 11 --value="127.0.0.1" || die "Failed to set trusted_proxies 11."
    fi

    # 2. Update Home Assistant Trusted Proxies
    if [[ -n "$ha_cid" ]]; then
        configure_ha_proxy_settings "$subnet" "$ha_cid"
    fi
}

function create_ha_admin() {
    local HA_PASSWORD="$1"
    if [ -z "$HA_PASSWORD" ]; then
        die "HA_PASSWORD not provided."
    fi

    log_info "Creating Home Assistant Admin Account..."
    local HA_URL="http://127.0.0.1:8123"
    
    # 1. Wait specifically for the API to be responsive (Container health != API ready)
    local retries=30  # Wait up to 60s
    local api_ready=false
    
    while [[ $retries -gt 0 ]]; do
        # We check /API/ (returns 401 if ready but unauth, or 200 if open)
        # We are looking for anything NOT 'Connection refused'
        local status=$(curl -s -o /dev/null -w "%{http_code}" "$HA_URL/manifest.json")
        if [[ "$status" != "000" ]]; then
            api_ready=true
            break
        fi
        sleep 2
        ((retries--))
    done

    if [ "$api_ready" = false ]; then
        log_warn "Home Assistant API did not become ready. Account creation skipped."
        return 1
    fi

    # 2. Check if onboarding is still active
    # If /api/onboarding returns 404 or [] or similar, it's already done.
    local onboarding_status=$(curl -s "$HA_URL/api/onboarding")
    
    # If the response contains "done" or is empty list, we skip
    if echo "$onboarding_status" | grep -q '"done":\[.*"user"'; then
        log_info "Home Assistant is already onboarded. Skipping account creation."
        return 0
    fi

    # 3. Create Account
    log_info "Creating 'admin' user..."
     
    # Capture response to validate success and extract Auth Token
    local response
    response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"Admin\", \"username\": \"admin\", \"password\": \"$HA_PASSWORD\", \"client_id\": \"http://homebrain.local/\"}" \
        "$HA_URL/api/onboarding/users")
 
    # Parse token using jq (installed in deps). If empty, creation failed.
    local token
    token=$(echo "$response" | jq -r '.auth_token // empty')
 
    if [[ -z "$token" ]]; then
        log_warn "Failed to create HA user. API did not return a token. Raw response: $response"
        return 1
    fi
         
    # 4. Finish Onboarding (Location/etc defaults) to close the loop
    # Use the token to authenticate these requests to ensure they are accepted.
    curl -s -X POST \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{"language":"en", "time_zone":"UTC", "elevation":0, "unit_system":"metric", "currency":"EUR"}' \
        "$HA_URL/api/onboarding/core_config" >/dev/null
 
    # 5. Finalize Onboarding (Integrations) - Critical step to mark onboarding as 'done'
    curl -s -X POST \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{"client_id":"http://homebrain.local/"}' \
        "$HA_URL/api/onboarding/integration" >/dev/null

    log_info "Home Assistant hardening complete."
}
