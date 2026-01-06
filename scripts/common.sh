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
    local CLIENT_ID="$HA_URL/"  # Use actual HA URL for client_id (per docs/examples)

    # 1. Wait for API readiness (container health != API ready)
    local retries=60  # Wait up to ~2min
    local api_ready=false
    local status
    while [[ $retries -gt 0 ]]; do
        status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$HA_URL/api/onboarding")
        if [[ "$status" == "200" ]]; then
            api_ready=true
            break
        fi
        sleep 2
        ((retries--))
    done

    if [ "$api_ready" = false ]; then
        log_warn "Home Assistant onboarding API did not become ready after 2min. Account creation skipped."
        return 1
    fi

    # 2. Check if onboarding is still needed (robust jq parsing)
    local onboarding_status=$(curl -s --max-time 10 "$HA_URL/api/onboarding")
    log_info "Onboarding status response: $onboarding_status"
    local user_done
    user_done=$(echo "$onboarding_status" | jq '.[] | select(.step == "user") | .done // false' 2>/dev/null) || user_done="false"
    if [[ "$user_done" == "true" ]]; then
        log_info "Home Assistant user onboarding already complete. Skipping account creation."
        return 0
    fi

    # 3. Create user account
    log_info "Creating 'admin' user..."
    local output=$(curl -s -w "\n%{http_code}" -X POST --max-time 10 \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"Admin\", \"username\": \"admin\", \"password\": \"$HA_PASSWORD\", \"language\": \"en\", \"client_id\": \"$CLIENT_ID\"}" \
        "$HA_URL/api/onboarding/users")
    local response=$(echo "$output" | head -n -1)
    local http_code=$(echo "$output" | tail -n1)
    
    log_info "User creation raw response: $response (HTTP: $http_code)"

    if [[ $http_code -ne 200 && $http_code -ne 201 ]]; then
        log_warn "User creation failed with HTTP $http_code. Response: $response"
        return 1
    fi

    # Parse auth_code (used in modern HA)
    local auth_code=$(echo "$response" | jq -r '.auth_code // empty')
    if [[ -z "$auth_code" ]]; then
        log_warn "Failed to create HA user. API did not return an auth_code. Raw response: $response"
        return 1
    fi

    # 4. Exchange auth_code for access_token (required for further onboarding)
    local token_output=$(curl -s -w "\n%{http_code}" -X POST --max-time 10 \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=authorization_code&code=$auth_code&client_id=$CLIENT_ID" \
        "$HA_URL/auth/token")
    local token_response=$(echo "$token_output" | head -n -1)
    local token_http_code=$(echo "$token_output" | tail -n1)
    
    if [[ $token_http_code -ne 200 ]]; then
        log_warn "Token exchange failed with HTTP $token_http_code. Response: $token_response"
        return 1
    fi
    
    local access_token=$(echo "$token_response" | jq -r '.access_token // empty')
    if [[ -z "$access_token" ]]; then
        log_warn "Failed to exchange auth_code for access_token. Raw response: $token_response"
        return 1
    fi

    # 5. Complete core_config onboarding step (minimal required post-user)
    local core_output=$(curl -s -w "\n%{http_code}" -X POST --max-time 10 \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json" \
        -d "{}" \
        "$HA_URL/api/onboarding/core_config")
    local core_response=$(echo "$core_output" | head -n -1)
    local core_http_code=$(echo "$core_output" | tail -n1)
    
    if [[ $core_http_code -ne 200 ]]; then
        log_warn "Core config failed with HTTP $core_http_code. Response: $core_response"
        return 1
    fi
    
    if [[ -z "$core_response" || "$core_response" != "{}" ]]; then  # Empty {} indicates success
        log_warn "Failed to complete core_config. Raw response: $core_response"
        return 1
    fi

    # 6. Verify overall onboarding (optional hardening: re-check status)
    onboarding_status=$(curl -s --max-time 10 "$HA_URL/api/onboarding")
    log_info "Post-onboarding status response: $onboarding_status"
    user_done=$(echo "$onboarding_status" | jq '.[] | select(.step == "user") | .done // false' 2>/dev/null) || user_done="false"
    local core_done=$(echo "$onboarding_status" | jq '.[] | select(.step == "core_config") | .done // false' 2>/dev/null) || core_done="false"
    if [[ "$user_done" != "true" || "$core_done" != "true" ]]; then
        log_warn "Onboarding verification failed post-creation. User done: $user_done, Core done: $core_done"
        return 1
    fi

    log_info "Home Assistant admin user created and minimal onboarding completed successfully."
    return 0
}
