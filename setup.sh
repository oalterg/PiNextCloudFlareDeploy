#!/bin/bash
# setup.sh — Idempotent and hardened setup for Nextcloud on Raspberry Pi (Non-Interactive)

echo "--- setup.sh script started ---"

set -euo pipefail

# --- Constants ---
readonly REPO_DIR="/opt/raspi-nextcloud-setup"
readonly ENV_FILE="$REPO_DIR/.env"
readonly ENV_TEMPLATE="$REPO_DIR/.env.template"
readonly COMPOSE_FILE="$REPO_DIR/docker-compose.yml"
readonly LOCK_FILE="/var/run/raspi-nextcloud-setup.lock"
readonly REQUIRED_CMDS=("curl" "git" "jq" "parted" "lsblk" "blkid" "docker" "cloudflared" "gpg")

# --- Helper Functions ---
die() { echo "[ERROR] $1" >&2; exit 1; }

wait_for_healthy() {
    local service_name="$1"
    local timeout_seconds="$2"
    local container_id
    echo "Waiting for $service_name to become healthy..."
    container_id=$(docker compose -f "$COMPOSE_FILE" ps -q "$service_name" 2>/dev/null)
    [[ -z "$container_id" ]] && die "Could not find container for service '$service_name'."
    local end_time=$((SECONDS + timeout_seconds))
    while [ $SECONDS -lt $end_time ]; do
        local status
        status=$(docker inspect --format="{{if .State.Health}}{{.State.Health.Status}}{{end}}" "$container_id" 2>/dev/null || echo "inspecting")
        [ "$status" == "healthy" ] && { echo "✅ $service_name is healthy."; return 0; }
        sleep 5
    done
    die "$service_name did not become healthy. Check logs: 'docker logs $container_id'."
}

auto_detect_backup_drive() {
    # Auto-scan: Largest removable/unmounted disk (non-root)
    local usb_dev
    usb_dev=$(lsblk -o NAME,TYPE,RM,SIZE,MOUNTPOINT | grep 'disk' | grep -v '^sda\|nvme0n1' | awk '$3=="1" && $5=="" {print "/dev/"$1; exit}')  # Removable, unmounted
    if [[ -n "$usb_dev" ]]; then
        echo "[*] Auto-detected external drive: $usb_dev ($(lsblk -o SIZE -n -d "$usb_dev"))"
        return 0
    else
        echo "[!] No external drive detected. Using local fallback."
        BACKUP_MOUNTDIR="/home/$SUDO_USER/backup"  # Safe default
        return 1
    fi
}

# --- Main Logic ---
preflight_checks() {
    echo "[*] Running pre-flight checks..."
    [[ $EUID -ne 0 ]] && die "This script must be run as root."

    if [[ -z "${SUDO_USER-}" ]]; then
        die "Could not determine the original user. Please run with 'sudo' (e.g., 'sudo /opt/raspi-nextcloud-setup/tui.sh'), not via 'sudo su' or a root shell."
    fi

    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            [[ "$cmd" == "curl" || "$cmd" == "git" ]] && die "Required command '$cmd' is not installed."
        fi
    done
    cd "$REPO_DIR"
    USER_HOME=$(eval echo "~$SUDO_USER")
    [[ -d "$USER_HOME" ]] || die "Could not determine home directory for user '$SUDO_USER'."
}

install_dependencies() {
    echo "[1/10] Installing system dependencies..."
    apt-get install -y ca-certificates curl gnupg lsb-release cron jq moreutils parted gpg

    # Docker setup (idempotent)
    if ! [ -f /etc/apt/keyrings/docker.gpg ]; then
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
        apt-get update -y
    fi
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Ensure Docker is running
    systemctl enable --now docker
    if ! systemctl is-active --quiet docker; then
        die "Docker failed to start. Check systemctl status docker."
    fi
    if ! [ -f /usr/share/keyrings/cloudflared.gpg ]; then
        mkdir -p --mode=0755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflared.gpg
        echo "deb [signed-by=/usr/share/keyrings/cloudflared.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflared.list
        apt-get update -y
    fi
    apt-get install -y cloudflared
}

gather_config_from_env() {
    echo "[2/10] Gathering configuration from environment..."
    : "${NEXTCLOUD_ADMIN_PASSWORD:?}" "${MYSQL_ROOT_PASSWORD:?}" "${MYSQL_PASSWORD:?}" "${BASE_DOMAIN:?}"
    SUBDOMAIN=${SUBDOMAIN:-nextcloud}
    CF_HOSTNAME="$SUBDOMAIN.$BASE_DOMAIN"
    NEXTCLOUD_TRUSTED_DOMAINS="$CF_HOSTNAME"
    NEXTCLOUD_ADMIN_USER="admin"
    MYSQL_USER="nextcloud_user"
    MYSQL_DATABASE="nextcloud"
    USER_HOME=$(eval echo "~$SUDO_USER")
    NEXTCLOUD_DATA_DIR="$USER_HOME/nextcloud"
    NEXTCLOUD_PORT="8080"
    BACKUP_LABEL="BackupDrive"
    BACKUP_MOUNTDIR="/mnt/backup"
    BACKUP_RETENTION=8
    # New: Auto-confirm format from env (TUI sets)
    AUTO_FORMAT_BACKUP="${AUTO_FORMAT_BACKUP:-false}"
    # New: Trusted proxies from env or default
    TRUSTED_PROXIES_0="${TRUSTED_PROXIES_0:-172.18.0.1}"
    TRUSTED_PROXIES_1="${TRUSTED_PROXIES_1:-127.0.0.1}"
}

setup_cloudflare() {
    echo "[3/10] Setting up Cloudflare Tunnel..."
    echo "You may need to authenticate with Cloudflare in your browser."
    if [ ! -f /root/.cloudflared/cert.pem ]; then
        echo "Certificate not found. Running 'cloudflared tunnel login'..."
        cloudflared tunnel login
        if [ ! -f /root/.cloudflared/cert.pem ]; then
            echo "Certificate still not found after login. If running over SSH, the cert.pem was likely downloaded to your local machine."
            echo "Please copy cert.pem to /root/.cloudflared/cert.pem on this device and rerun the script."
            die "Missing Cloudflare certificate."
        fi
    fi
    local TUNNEL_NAME="nextcloud-tunnel-$SUBDOMAIN"
    CF_TUNNEL_ID=$(cloudflared tunnel list --output json 2>/dev/null | jq -r ".[] | select(.name==\"$TUNNEL_NAME\") | .id" || true)
    if [[ -z "$CF_TUNNEL_ID" || "$CF_TUNNEL_ID" == "null" ]]; then
        echo "Creating new tunnel: $TUNNEL_NAME"
        CF_TUNNEL_ID=$(cloudflared tunnel create "$TUNNEL_NAME" | awk '/Created tunnel/{print $NF}')
    else
        echo "Reusing existing tunnel ID: $CF_TUNNEL_ID"
    fi
    echo "Routing DNS for $CF_HOSTNAME..."
    cloudflared tunnel route dns "$TUNNEL_NAME" "$CF_HOSTNAME" || echo "DNS route may already exist. Continuing..."
    local CREDENTIALS_FILE="/root/.cloudflared/${CF_TUNNEL_ID}.json"
    mkdir -p /etc/cloudflared
    cat > /etc/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_NAME
credentials-file: $CREDENTIALS_FILE
ingress:
  - hostname: $CF_HOSTNAME
    service: http://localhost:$NEXTCLOUD_PORT
  - service: http_status:404
EOF
    cat >/etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel for Nextcloud
After=network-online.target
[Service]
Type=notify
ExecStart=/usr/bin/cloudflared --config /etc/cloudflared/config.yml tunnel run
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if systemctl is-enabled --quiet cloudflared 2>/dev/null; then
        echo "[*] Service already enabled, restarting..."
        systemctl restart cloudflared
    else
        echo "[*] Enabling and starting service..."
        systemctl enable --now cloudflared
    fi
}

generate_env_file() {
    echo "[4/10] Generating .env configuration file..."
    [[ -f "$ENV_TEMPLATE" ]] || die "Missing .env.template file."

    mkdir -p "$NEXTCLOUD_DATA_DIR"
    chown -R 33:33 "$NEXTCLOUD_DATA_DIR"
    cp "$ENV_TEMPLATE" "$ENV_FILE"

    # Apply sed with validation
    sed -i -e "s|^NEXTCLOUD_ADMIN_PASSWORD=.*|NEXTCLOUD_ADMIN_PASSWORD=$NEXTCLOUD_ADMIN_PASSWORD|" \
      -e "s|^NEXTCLOUD_TRUSTED_DOMAINS=.*|NEXTCLOUD_TRUSTED_DOMAINS=$NEXTCLOUD_TRUSTED_DOMAINS|" \
      -e "s|^NEXTCLOUD_PORT=.*|NEXTCLOUD_PORT=$NEXTCLOUD_PORT|" \
      -e "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD|" \
      -e "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=$MYSQL_PASSWORD|" \
      -e "s|^NEXTCLOUD_DATA_DIR=.*|NEXTCLOUD_DATA_DIR=$NEXTCLOUD_DATA_DIR|" \
      -e "s|^BACKUP_MOUNTDIR=.*|BACKUP_MOUNTDIR=$BACKUP_MOUNTDIR|" \
      -e "s|^BACKUP_LABEL=.*|BACKUP_LABEL=$BACKUP_LABEL|" \
      -e "s|^BACKUP_RETENTION=.*|BACKUP_RETENTION=$BACKUP_RETENTION|" \
      -e "s|^CF_TUNNEL_ID=.*|CF_TUNNEL_ID=$CF_TUNNEL_ID|" \
      -e "s|^TRUSTED_PROXIES_0=.*|TRUSTED_PROXIES_0=$TRUSTED_PROXIES_0|" \
      -e "s|^TRUSTED_PROXIES_1=.*|TRUSTED_PROXIES_1=$TRUSTED_PROXIES_1|" \
      -e "s|^AUTO_FORMAT_BACKUP=.*|AUTO_FORMAT_BACKUP=$AUTO_FORMAT_BACKUP|" \
      "$ENV_FILE"

    # Validate key vars
    grep -q "NEXTCLOUD_ADMIN_PASSWORD=$NEXTCLOUD_ADMIN_PASSWORD" "$ENV_FILE" || die "Failed to update .env (admin password)."
    grep -q "CF_TUNNEL_ID=$CF_TUNNEL_ID" "$ENV_FILE" || die "Failed to update .env (tunnel ID)."

    chmod 600 "$ENV_FILE"
}

deploy_docker_stack() {
    echo "[5/10] Deploying Docker stack..."
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --remove-orphans
    wait_for_healthy "db" 120
    wait_for_healthy "nextcloud" 180
}

configure_nextcloud_https() {
    echo "[6/10] Applying reverse proxy HTTPS configuration..."
    local NC_CID
    NC_CID=$(docker compose -f "$COMPOSE_FILE" ps -q nextcloud)
    [[ -z "$NC_CID" ]] && die "Nextcloud container not ready."

    docker exec --user www-data "$NC_CID" php occ config:system:set overwriteprotocol --value=https || die "Failed to set overwriteprotocol."
    docker exec --user www-data "$NC_CID" php occ config:system:set trusted_proxies 0 --value="$TRUSTED_PROXIES_0" || die "Failed to set trusted_proxies 0."
    docker exec --user www-data "$NC_CID" php occ config:system:set trusted_proxies 1 --value="$TRUSTED_PROXIES_1" || die "Failed to set trusted_proxies 1."

    echo "Restarting Nextcloud service..."
    docker compose -f "$COMPOSE_FILE" restart nextcloud
    wait_for_healthy "nextcloud" 120
}

setup_backup_drive() {
    echo "[7/10] Setting up backup drive (auto-scan)..."
    mkdir -p "$BACKUP_MOUNTDIR"
    if mountpoint -q "$BACKUP_MOUNTDIR"; then 
        echo "Backup directory is already a mountpoint."; 
        return 0; 
    fi

    # Auto-detect
    if ! auto_detect_backup_drive; then
        echo "Using local fallback: $BACKUP_MOUNTDIR"
        return 0
    fi

    local dev="$usb_dev"  # From auto_detect
    local fs_type
    fs_type=$(blkid -o value -s TYPE "$dev" 2>/dev/null)

    if [[ "$AUTO_FORMAT_BACKUP" == "true" && -z "$fs_type" ]]; then
        echo "[*] Formatting detected drive (destructive—proceed with caution)..."
        mkfs.ext4 -F -L "$BACKUP_LABEL" "$dev"
    elif [[ -z "$fs_type" ]]; then
        die "Drive detected but unformatted. Set AUTO_FORMAT_BACKUP=true in env or format manually."
    fi

    # Mount idempotently
    umount "$BACKUP_MOUNTDIR" 2>/dev/null || true
    mount -t "${fs_type:-ext4}" -L "$BACKUP_LABEL" "$BACKUP_MOUNTDIR" || die "Failed to mount backup drive."
    
    # fstab update
    local UUID
    UUID=$(blkid -o value -s UUID "$dev")
    if ! grep -q "$UUID" /etc/fstab; then
        echo "UUID=$UUID $BACKUP_MOUNTDIR ${fs_type:-ext4} defaults,nofail 0 2" >> /etc/fstab
        echo "Added backup drive to /etc/fstab."
    fi
}

offer_restore() {
    echo "[8/10] Skipping restore check during initial setup."
}

install_backup_cronjob() {
    echo "[9/10] Installing weekly backup cron job..."
    if ! mountpoint -q "$BACKUP_MOUNTDIR"; then
        echo "Warning: Backup directory not mounted. Cron job NOT installed."
        return 0
    fi

    chmod +x "$REPO_DIR/backup.sh"
    local cron_content="# Run weekly Nextcloud backup on Sunday at 03:00\n0 3 * * 0 root $REPO_DIR/backup.sh >> /var/log/raspi-nextcloud/backup.log 2>&1\n"

    if [[ -f /etc/cron.d/nextcloud-backup && $(cat /etc/cron.d/nextcloud-backup) == "$cron_content" ]]; then
        echo "Cron job already installed and up-to-date."
    else
        echo "$cron_content" > /etc/cron.d/nextcloud-backup
        chmod 644 /etc/cron.d/nextcloud-backup
        echo "Cron job installed/updated."
    fi
}

validate_setup() {
    echo "[10/10] Validating setup..."
    sleep 10
    if curl -f -k "https://$CF_HOSTNAME/status.php" >/dev/null 2>&1; then
        echo "✅ Nextcloud is accessible at: https://$CF_HOSTNAME"
    else
        echo "⚠️ Setup complete, but accessibility check failed. Check Cloudflare tunnel and firewall."
    fi
}

main() {
    exec 200>"$LOCK_FILE"
    flock -n 200 || die "Setup script is already running."
    trap 'rm -f "$LOCK_FILE"; echo "Lock cleaned up." >&2' EXIT
    
    preflight_checks
    install_dependencies
    
    if [[ "${1-}" == "--non-interactive" ]]; then
        gather_config_from_env
    else
        die "This script is intended to be run non-interactively via the TUI."
    fi
    
    setup_cloudflare
    generate_env_file
    deploy_docker_stack
    configure_nextcloud_https
    setup_backup_drive
    offer_restore
    install_backup_cronjob
    validate_setup

    echo "✅ Installation complete!"
}

main "$@"