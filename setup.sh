#!/bin/bash
# setup.sh — Raspberry Pi Nextcloud + Cloudflare Tunnel full setup

set -e

REPO_DIR="/opt/raspi-nextcloud-setup"
ENV_FILE="$REPO_DIR/.env"
CF_API_BASE="https://api.cloudflare.com/client/v4"

echo "=== Raspberry Pi Nextcloud Setup ==="

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo ./setup.sh)"
    exit 1
fi

mkdir -p "$REPO_DIR"
cd "$REPO_DIR"

# --- OS preparation ---
echo "[1/12] Updating system..."
apt-get update -y && apt-get upgrade -y

echo "[2/12] Installing dependencies..."
apt-get install -y \
    docker.io docker-compose-plugin \
    cloudflared \
    cron git curl jq

systemctl enable docker
systemctl start docker

grep -q "dtparam=pciex1_gen=3" /boot/config.txt || echo "dtparam=pciex1_gen=3" >> /boot/config.txt
grep -q "dtoverlay=disable-wifi" /boot/config.txt || echo "dtoverlay=disable-wifi" >> /boot/config.txt

# --- Gather parameters ---
echo "[3/12] Gathering configuration..."
read -rp "Nextcloud admin username [admin]: " NEXTCLOUD_ADMIN_USER
NEXTCLOUD_ADMIN_USER=${NEXTCLOUD_ADMIN_USER:-admin}
read -rp "Nextcloud admin password: " NEXTCLOUD_ADMIN_PASSWORD
read -rp "Nextcloud domain (e.g., cloud.example.com): " NEXTCLOUD_TRUSTED_DOMAINS

read -rp "MySQL root password: " MYSQL_ROOT_PASSWORD
read -rp "MySQL user [nextcloud]: " MYSQL_USER
MYSQL_USER=${MYSQL_USER:-nextcloud}
read -rp "MySQL user password: " MYSQL_PASSWORD
MYSQL_DATABASE="nextcloud"

USER_HOME=$(eval echo "~$SUDO_USER")
NEXTCLOUD_DATA_DIR="$USER_HOME/nextcloud"

if [[ ! -d "$NEXTCLOUD_DATA_DIR" ]]; then
    echo "Nextcloud data directory $NEXTCLOUD_DATA_DIR not found — creating..."
    mkdir -p "$NEXTCLOUD_DATA_DIR"
    chown -R 33:33 "$NEXTCLOUD_DATA_DIR"
fi

read -rp "Backup directory [/mnt/backupssd]: " BACKUP_DIR
BACKUP_DIR=${BACKUP_DIR:-/mnt/backupssd}

if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "Backup directory $BACKUP_DIR not found — creating..."
    mkdir -p "$BACKUP_DIR"
fi

read -rp "Cloudflare API token: " CF_API_TOKEN

BASE_DOMAIN=$(echo "$NEXTCLOUD_TRUSTED_DOMAINS" | sed 's/.*\.\([^.]*\.[^.]*\)$/\1/')

# --- Validate Cloudflare API token ---
echo "[4/12] Validating Cloudflare API token..."
if ! curl -s -X GET "$CF_API_BASE/user/tokens/verify" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" | jq -e '.success' >/dev/null; then
    echo "Error: Invalid Cloudflare API token"
    exit 1
fi

# --- Cloudflare Tunnel setup ---
TUNNEL_NAME="nextcloud-tunnel"
echo "[5/12] Cloudflare tunnel setup..."
cloudflared tunnel login

EXISTING_TUNNEL_ID=$(cloudflared tunnel list --output json 2>/dev/null | jq -r ".[] | select(.name==\"$TUNNEL_NAME\") | .id" || true)
if [[ -n "$EXISTING_TUNNEL_ID" && "$EXISTING_TUNNEL_ID" != "null" ]]; then
    CF_TUNNEL_ID="$EXISTING_TUNNEL_ID"
    echo "Reusing tunnel ID: $CF_TUNNEL_ID"
else
    CF_TUNNEL_ID=$(cloudflared tunnel create "$TUNNEL_NAME" | grep -oP "(?<=Created tunnel ).*")
fi

CF_CERT_PATH="/root/.cloudflared/cert.pem"
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml <<EOF
tunnel: $CF_TUNNEL_ID
credentials-file: $CF_CERT_PATH

ingress:
  - hostname: $NEXTCLOUD_TRUSTED_DOMAINS
    service: http://localhost:8080
  - service: http_status:404
EOF

systemctl enable cloudflared
systemctl restart cloudflared

# --- DNS setup ---
echo "[6/12] Configuring DNS..."
ZONE_ID=$(curl -s -X GET "$CF_API_BASE/zones?name=$BASE_DOMAIN" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')

if [[ "$ZONE_ID" == "null" || -z "$ZONE_ID" ]]; then
    echo "Error: Could not find Zone ID for $BASE_DOMAIN"
    exit 1
fi

RECORD_ID=$(curl -s -X GET "$CF_API_BASE/zones/$ZONE_ID/dns_records?name=$NEXTCLOUD_TRUSTED_DOMAINS" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')

DESIRED_TARGET="$CF_TUNNEL_ID.cfargotunnel.com"

if [[ "$RECORD_ID" != "null" && -n "$RECORD_ID" ]]; then
    CURRENT_TARGET=$(curl -s -X GET "$CF_API_BASE/zones/$ZONE_ID/dns_records/$RECORD_ID" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" | jq -r '.result.content')
    if [[ "$CURRENT_TARGET" != "$DESIRED_TARGET" ]]; then
        echo "Updating DNS..."
        curl -s -X PUT "$CF_API_BASE/zones/$ZONE_ID/dns_records/$RECORD_ID" \
          -H "Authorization: Bearer $CF_API_TOKEN" \
          -H "Content-Type: application/json" \
          --data "{\"type\":\"CNAME\",\"name\":\"$NEXTCLOUD_TRUSTED_DOMAINS\",\"content\":\"$DESIRED_TARGET\",\"ttl\":1,\"proxied\":true}" >/dev/null
    else
        echo "DNS already correct."
    fi
else
    echo "Creating DNS..."
    curl -s -X POST "$CF_API_BASE/zones/$ZONE_ID/dns_records" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"CNAME\",\"name\":\"$NEXTCLOUD_TRUSTED_DOMAINS\",\"content\":\"$DESIRED_TARGET\",\"ttl\":1,\"proxied\":true}" >/dev/null
fi

# --- Save env ---
cat > "$ENV_FILE" <<EOF
NEXTCLOUD_DATA_DIR=$NEXTCLOUD_DATA_DIR
BACKUP_DIR=$BACKUP_DIR
NEXTCLOUD_ADMIN_USER=$NEXTCLOUD_ADMIN_USER
NEXTCLOUD_ADMIN_PASSWORD=$NEXTCLOUD_ADMIN_PASSWORD
NEXTCLOUD_TRUSTED_DOMAINS=$NEXTCLOUD_TRUSTED_DOMAINS
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
MYSQL_PASSWORD=$MYSQL_PASSWORD
MYSQL_DATABASE=$MYSQL_DATABASE
MYSQL_USER=$MYSQL_USER
CF_TUNNEL_ID=$CF_TUNNEL_ID
CF_CERT_PATH=$CF_CERT_PATH
CF_API_TOKEN=$CF_API_TOKEN
EOF

# --- Docker compose ---
echo "[7/12] Writing docker-compose.yml..."
cat > "$REPO_DIR/docker-compose.yml" <<EOF
services:
  nextcloud:
    image: nextcloud:latest
    restart: unless-stopped
    ports:
      - "8080:80"
    environment:
      - NEXTCLOUD_ADMIN_USER=\${NEXTCLOUD_ADMIN_USER}
      - NEXTCLOUD_ADMIN_PASSWORD=\${NEXTCLOUD_ADMIN_PASSWORD}
      - NEXTCLOUD_TRUSTED_DOMAINS=\${NEXTCLOUD_TRUSTED_DOMAINS}
      - MYSQL_PASSWORD=\${MYSQL_PASSWORD}
      - MYSQL_DATABASE=\${MYSQL_DATABASE}
      - MYSQL_USER=\${MYSQL_USER}
      - MYSQL_HOST=db
    volumes:
      - nextcloud:/var/www/html
      - \${NEXTCLOUD_DATA_DIR}:/var/www/html/data
    depends_on:
      - db
  db:
    image: mariadb:latest
    restart: unless-stopped
    environment:
      - MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASSWORD}
      - MYSQL_PASSWORD=\${MYSQL_PASSWORD}
      - MYSQL_DATABASE=\${MYSQL_DATABASE}
      - MYSQL_USER=\${MYSQL_USER}
    volumes:
      - db_data:/var/lib/mysql
volumes:
  nextcloud:
  db_data:
EOF

# --- Deploy ---
echo "[8/12] Deploying Docker stack..."
docker compose --env-file "$ENV_FILE" -f "$REPO_DIR/docker-compose.yml" up -d

# --- Backup setup ---
echo "[9/12] Installing backup script..."
chmod +x "$REPO_DIR/backup.sh"

if mountpoint -q "$BACKUP_DIR"; then
    echo "Enabling cron job..."
    (crontab -l 2>/dev/null | grep -v "$REPO_DIR/backup.sh" ; echo "0 3 * * 0 $REPO_DIR/backup.sh") | crontab -
else
    echo "Warning: Backup directory is not mounted. Skipping cron job."
fi

echo "[10/12] Installation complete."
echo "[11/12] Access Nextcloud at: https://$NEXTCLOUD_TRUSTED_DOMAINS"
echo "[12/12] Rebooting in 5 seconds..."
sleep 5
reboot
