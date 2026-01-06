#!/bin/bash
set -euo pipefail

# --- Configuration ---
# distinct APP_DIR removed; we run directly from the repo structure
INSTALL_DIR="/opt/homebrain"
SERVICE_DIR="$INSTALL_DIR/src"
BOOT_CONFIG="/boot/firmware/factory_config.txt"
LOG_DIR="/var/log/homebrain"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/common.sh"

# --- Input Validation ---
if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi
if [ "$#" -ne 5 ]; then echo "Usage: $0 <ID> <SECRET> <MAIN_DOMAIN> <PAN_EP> <FACTORY_PASS>"; exit 1; fi

# --- 1. System Dependencies ---
echo "Installing Application Dependencies..."
install_deps_enable_docker

# --- 2. Write Factory Config ---
echo "Writing factory configuration..."
cat > "$BOOT_CONFIG" <<EOF
NEWT_ID=${1}
NEWT_SECRET=${2}
PANGOLIN_DOMAIN=${3}
PANGOLIN_ENDPOINT=${4}
FACTORY_PASSWORD=${5}
EOF
chmod 600 "$BOOT_CONFIG"

# --- 3. Setup Python Environment ---
echo "Provisioning HomeBrain Manager..."

# Install Requirements directly from the service directory
if [ -f "$INSTALL_DIR/requirements.txt" ]; then
    echo "Installing Python requirements..."
    pip3 install -r "$INSTALL_DIR/requirements.txt" --break-system-packages
fi

# 4. Ensure scripts are executable
chmod +x "$INSTALL_DIR/scripts/"*.sh

# --- 5. Install Service ---
echo "Configuring Systemd Service..."

# Copy the service file
SERVICE_FILE="$INSTALL_DIR/config/homebrain-manager.service"

if [ -f "$SERVICE_FILE" ]; then
    cp "$SERVICE_FILE" /etc/systemd/system/

    systemctl daemon-reload
    systemctl enable --now homebrain-manager.service
else
    echo "ERROR: Service file not found at $SERVICE_FILE"
    exit 1
fi

echo "HomeBrain Provisioning Complete."
echo "======================================================="
echo "   PROVISIONING COMPLETE"
echo "======================================================="
echo "   Device is ready for first boot."
echo "   Password will be generated during deployment."
echo "======================================================="
