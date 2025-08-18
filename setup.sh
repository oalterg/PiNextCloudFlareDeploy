#!/bin/bash
# setup.sh — Raspberry Pi Nextcloud + Cloudflare Tunnel setup
# - Deploys stack first
# - Then prepares backup drive (auto-detect, optional format)
# - Then offers restore from latest backup
set -euo pipefail

REPO_DIR="/opt/raspi-nextcloud-setup"
ENV_FILE="$REPO_DIR/.env"
ENV_TEMPLATE="$REPO_DIR/.env.template"
COMPOSE_FILE="$REPO_DIR/docker-compose.yml"
BACKUP_DIR="/mnt/backup"
BACKUP_LABEL="${BACKUP_LABEL:-BackupDrive}"   # consistent across scripts

echo "=== Raspberry Pi Nextcloud Setup ==="

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo ./setup.sh)"
  exit 1
fi

# ensure interactive prompts even if script is piped
exec < /dev/tty

cd "$REPO_DIR"

# --- OS preparation ---
echo "[1/14] Updating system..."
apt-get update -y && apt-get upgrade -y

echo "[2/12] Installing dependencies..."
# Docker (official repo + compose plugin)
apt-get install -y ca-certificates curl gnupg lsb-release
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

  apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Cloudflared
# Add cloudflare gpg key
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
# Add this repo to your apt repositories
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
# install cloudflared
sudo apt-get update && sudo apt-get install cloudflared

# Other tools
apt-get install -y cron git jq moreutils

systemctl enable docker
systemctl start docker

# --- Gather parameters ---
echo "[3/14] Gathering configuration..."
read -rp "Nextcloud admin username [admin]: " NEXTCLOUD_ADMIN_USER
NEXTCLOUD_ADMIN_USER=${NEXTCLOUD_ADMIN_USER:-admin}
read -rp "Nextcloud admin password: " NEXTCLOUD_ADMIN_PASSWORD

# multiple domains allowed (space-separated)
read -rp "Nextcloud domain(s) (space-separated, e.g. pinextcloud.local cloud.example.com): " NEXTCLOUD_TRUSTED_DOMAINS
DOMAIN_ARRAY=($NEXTCLOUD_TRUSTED_DOMAINS)
PRIMARY_DOMAIN="${DOMAIN_ARRAY[0]}"

read -rp "MySQL root password: " MYSQL_ROOT_PASSWORD
read -rp "MySQL user [nextcloud]: " MYSQL_USER
MYSQL_USER=${MYSQL_USER:-nextcloud}
read -rp "MySQL user password: " MYSQL_PASSWORD
MYSQL_DATABASE="nextcloud"

USER_HOME=$(eval echo "~$SUDO_USER")
NEXTCLOUD_DATA_DIR="$USER_HOME/nextcloud"
NEXTCLOUD_PORT="${NEXTCLOUD_PORT:-8080}"

mkdir -p "$NEXTCLOUD_DATA_DIR"
chown -R 33:33 "$NEXTCLOUD_DATA_DIR"

# Default backup dir (can be remounted to a labeled drive later)
read -rp "Backup directory [$(${ECHO_BACKUP_DIR:-echo /mnt/backupssd})]: " BACKUP_DIR_INPUT
BACKUP_DIR="${BACKUP_DIR_INPUT:-/mnt/backupssd}"
mkdir -p "$BACKUP_DIR"

# --- Cloudflare Tunnel (optional, tokenless) ---
echo "[4/14] Cloudflare tunnel setup..."
read -rp "Use Cloudflare Tunnel? [y/N]: " USE_CF
USE_CF=${USE_CF:-n}

CF_TUNNEL_ID=""
CF_HOSTNAME=""
if [[ "$USE_CF" =~ ^[Yy]$ ]]; then
  echo "Logging into Cloudflare (a URL will open in your browser)..."
  cloudflared tunnel login

  read -rp "Enter your base domain (already in Cloudflare, e.g. example.com): " BASE_DOMAIN
  read -rp "Enter desired subdomain (e.g. nextcloud): " SUBDOMAIN
  CF_HOSTNAME="$SUBDOMAIN.$BASE_DOMAIN"

  TUNNEL_NAME="nextcloud-tunnel"
  EXISTING_TUNNEL_ID=$(cloudflared tunnel list --output json 2>/dev/null | jq -r ".[] | select(.name==\"$TUNNEL_NAME\") | .id" || true)
  if [[ -n "$EXISTING_TUNNEL_ID" && "$EXISTING_TUNNEL_ID" != "null" ]]; then
    CF_TUNNEL_ID="$EXISTING_TUNNEL_ID"
    echo "Reusing tunnel ID: $CF_TUNNEL_ID"
  else
    CF_TUNNEL_ID=$(cloudflared tunnel create "$TUNNEL_NAME" | awk '/Created tunnel/{print $3}')
    echo "Created new tunnel: $CF_TUNNEL_ID"
  fi

  echo "Routing DNS for $CF_HOSTNAME..."
  cloudflared tunnel route dns "$TUNNEL_NAME" "$CF_HOSTNAME"

  CREDENTIALS_FILE="/root/.cloudflared/${CF_TUNNEL_ID}.json"
  mkdir -p /etc/cloudflared
  cat > /etc/cloudflared/config.yml <<EOF
tunnel: $CF_TUNNEL_ID
credentials-file: $CREDENTIALS_FILE

ingress:
  - hostname: $CF_HOSTNAME
    service: http://localhost:$NEXTCLOUD_PORT
  - service: http_status:404
EOF

  # Create a reliable systemd service
  cat >/etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=0
Type=notify
ExecStart=/usr/bin/cloudflared --config /etc/cloudflared/config.yml tunnel run
Restart=on-failure
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable cloudflared
  systemctl restart cloudflared
fi

# --- Generate .env ---
echo "[5/14] Writing .env..."
cp "$ENV_TEMPLATE" "$ENV_FILE"
sed -i \
  -e "s|NEXTCLOUD_DATA_DIR=.*|NEXTCLOUD_DATA_DIR=$NEXTCLOUD_DATA_DIR|" \
  -e "s|BACKUP_DIR=.*|BACKUP_DIR=$BACKUP_DIR|" \
  -e "s|NEXTCLOUD_ADMIN_USER=.*|NEXTCLOUD_ADMIN_USER=$NEXTCLOUD_ADMIN_USER|" \
  -e "s|NEXTCLOUD_ADMIN_PASSWORD=.*|NEXTCLOUD_ADMIN_PASSWORD=$NEXTCLOUD_ADMIN_PASSWORD|" \
  -e "s|NEXTCLOUD_TRUSTED_DOMAINS=.*|NEXTCLOUD_TRUSTED_DOMAINS=$NEXTCLOUD_TRUSTED_DOMAINS|" \
  -e "s|NEXTCLOUD_PORT=.*|NEXTCLOUD_PORT=$NEXTCLOUD_PORT|" \
  -e "s|MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD|" \
  -e "s|MYSQL_PASSWORD=.*|MYSQL_PASSWORD=$MYSQL_PASSWORD|" \
  -e "s|MYSQL_DATABASE=.*|MYSQL_DATABASE=$MYSQL_DATABASE|" \
  -e "s|MYSQL_USER=.*|MYSQL_USER=$MYSQL_USER|" \
  -e "s|CF_TUNNEL_ID=.*|CF_TUNNEL_ID=$CF_TUNNEL_ID|" \
  -e "s|BACKUP_LABEL=.*|BACKUP_LABEL=$BACKUP_LABEL|" \
  "$ENV_FILE"

# --- Deploy ---
echo "[6/9] Deploying Docker stack..."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d
echo "Waiting a moment for containers to settle..."
sleep 10

# --- Backup drive: auto-detect & (optional) format ---
echo "[8/14] Backup drive detection..."
# If BACKUP_DIR not a mountpoint, offer to prep a drive
if ! mountpoint -q "$BACKUP_DIR"; then
  # Prefer labeled partition
  if blkid -L "$BACKUP_LABEL" >/dev/null 2>&1; then
    echo "Found partition with label '$BACKUP_LABEL'. Mounting to $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    mount -L "$BACKUP_LABEL" "$BACKUP_DIR" || echo "Mount by label failed."
  fi
fi

if ! mountpoint -q "$BACKUP_DIR"; then
  CANDIDATE_DRIVE=$(lsblk -dpno NAME,TYPE,MOUNTPOINT | awk '$2=="disk" && $3=="" {print $1}' | head -n1 || true)
  if [[ -n "${CANDIDATE_DRIVE:-}" ]]; then
    echo "Detected unmounted drive: $CANDIDATE_DRIVE"
    read -rp "Partition/format this drive as ext4 and label '$BACKUP_LABEL'? [y/N]: " FORMAT_DRIVE
    if [[ "$FORMAT_DRIVE" =~ ^[Yy]$ ]]; then
      echo "Partitioning + formatting $CANDIDATE_DRIVE..."
      parted -s "$CANDIDATE_DRIVE" mklabel gpt
      parted -s "$CANDIDATE_DRIVE" mkpart primary ext4 0% 100%
      sleep 2
      PARTITION="${CANDIDATE_DRIVE}1"
      mkfs.ext4 -F -L "$BACKUP_LABEL" "$PARTITION"
      mkdir -p "$BACKUP_DIR"
      mount -L "$BACKUP_LABEL" "$BACKUP_DIR"
      UUID=$(blkid -s UUID -o value "$PARTITION")
      grep -q "$UUID" /etc/fstab || echo "UUID=$UUID $BACKUP_DIR ext4 defaults 0 2" >> /etc/fstab
      echo "Backup drive mounted at $BACKUP_DIR."
    else
      echo "Skipping drive preparation. You can mount manually later."
    fi
  else
    echo "No spare unmounted drive detected."
  fi
else
  echo "Backup directory is mounted: $BACKUP_DIR"
fi

# --- Offer restore (AFTER stack is running) ---
echo "[9/14] Checking for existing backups to restore..."
LATEST_BACKUP="$(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -n1 || true)"
if [[ -n "${LATEST_BACKUP:-}" ]]; then
  echo "Latest backup found: $LATEST_BACKUP"
  read -rp "Do you want to restore this backup now? [y/N]: " DO_RESTORE
  if [[ "$DO_RESTORE" =~ ^[Yy]$ ]]; then
    echo "Invoking restore.sh..."
    chmod +x "$REPO_DIR/restore.sh"
    "$REPO_DIR/restore.sh" "$LATEST_BACKUP"
  fi
else
  echo "No backups found in $BACKUP_DIR."
fi

# --- Install backup job ---
echo "[10/14] Installing backup script + cron..."

if mountpoint -q "$BACKUP_DIR"; then
  chmod +x "$REPO_DIR/backup.sh"
  cat >/etc/cron.d/nextcloud-backup <<EOF
# Run weekly Sunday 03:00 as root
0 3 * * 0 root $REPO_DIR/backup.sh >> /var/log/nextcloud-backup.log 2>&1
EOF
  chmod 644 /etc/cron.d/nextcloud-backup
else
  echo "Warning: $BACKUP_DIR is not mounted. Cron job not installed."
fi


echo "[11-14/14] Installation complete."
if [[ "$USE_CF" =~ ^[Yy]$ ]]; then
  echo "Access Nextcloud at: https://$CF_HOSTNAME"
else
  echo "Access Nextcloud locally at: http://$PRIMARY_DOMAIN:$NEXTCLOUD_PORT"
fi
