#!/bin/bash
set -euo pipefail

# --- Configuration ---
APP_DIR="/opt/appliance-manager"
REPO_DIR="/opt/raspi-nextcloud-setup"
BOOT_CONFIG="/boot/firmware/factory_config.txt"

# --- Input Validation ---
if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi
if [ "$#" -ne 5 ]; then echo "Usage: $0 <ID> <SECRET> <NC_DOM> <HA_DOM> <PAN_EP>"; exit 1; fi

# --- 1. System Dependencies ---
echo "Installing Application Dependencies..."
apt-get update -qq
apt-get install -y python3-flask python3-dotenv python3-pip jq moreutils pwgen git parted

# --- 2. Write Factory Config ---
echo "Writing factory configuration..."
cat > "$BOOT_CONFIG" <<EOF
NEWT_ID=${1}
NEWT_SECRET=${2}
NC_DOMAIN=${3}
HA_DOMAIN=${4}
PANGOLIN_ENDPOINT=${5}
HA_ENABLED=$([[ -n "${4}" ]] && echo "true" || echo "false")
EOF
chmod 600 "$BOOT_CONFIG"

# --- 3. Deploy Application Files ---
echo "Deploying Web Manager..."
mkdir -p "$APP_DIR/templates"

# Copy from the REPO_DIR (setup by the install script) to the APP_DIR (running service)
cp "$REPO_DIR/src/app.py" "$APP_DIR/"
cp -r "$REPO_DIR/src/templates/"* "$APP_DIR/templates/"

# --- 4. Install Docker Compose Configuration ---
echo "Deploying Docker Compose Configuration..."
cp "$REPO_DIR/config/docker-compose.yml" "$REPO_DIR/"

# --- 5. Install Service ---
echo "Configuring Systemd Service..."
# Copy the service file
cp "$REPO_DIR/config/appliance-manager.service" /etc/systemd/system/

sed -i "s|\$APP_DIR|$APP_DIR|g" /etc/systemd/system/appliance-manager.service

systemctl daemon-reload
systemctl enable --now appliance-manager.service

echo "Provisioning Complete. Web UI available on port 80."