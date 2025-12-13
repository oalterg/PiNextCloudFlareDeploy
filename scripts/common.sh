#!/bin/bash

# --- Global Configuration ---
export REPO_DIR="/opt/raspi-nextcloud-setup"
export LOG_DIR="/var/log/raspi-nextcloud"
export ENV_FILE="$REPO_DIR/.env"
export COMPOSE_FILE="$REPO_DIR/docker-compose.yml"
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
get_nc_cid() {
    docker compose -f "$COMPOSE_FILE" ps -q nextcloud 2>/dev/null || true
}

get_ha_cid() {
    docker compose -f "$COMPOSE_FILE" ps -q homeassistant 2>/dev/null || true
}

is_stack_running() {
    [[ -n "$(get_nc_cid)" ]]
}

# --- Tunnel Profiles Helper ---
get_tunnel_profiles() {
    local profiles=""
    local cf_mode=false
    if [[ -n "${CF_TOKEN_NC:-}" ]] || [[ -n "${CF_TOKEN_HA:-}" ]]; then
        cf_mode=true
    fi

    if [[ "${cf_mode}" = true ]]; then
        if [[ -n "${CF_TOKEN_NC:-}" ]]; then
            profiles="${profiles} --profile cloudflare-nc"
        fi
        if [[ -n "${CF_TOKEN_HA:-}" ]] && [[ "${HA_ENABLED:-false}" = "true" ]]; then
            profiles="${profiles} --profile cloudflare-ha"
        fi
        if [[ -z "${profiles}" ]]; then
            log_warn "Cloudflare mode detected but no valid tokens found. Falling back to local-only."
        fi
    else
        if [[ -n "${PANGOLIN_ENDPOINT:-}" ]] && [[ -n "${NEWT_ID:-}" ]] && [[ -n "${NEWT_SECRET:-}" ]]; then
            profiles="${profiles} --profile pangolin"
        else
            log_warn "No complete Pangolin configuration found. Deploying without tunnel."
        fi
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
        container_id=$(docker compose -f "$COMPOSE_FILE" ps -q "$service_name" 2>/dev/null)
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