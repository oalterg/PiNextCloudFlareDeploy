#!/bin/bash
# install.sh — lightweight bootstrapper for raspi-nextcloud-setup (bulletproof)

set -Eeuo pipefail

REPO_URL="https://github.com/YOURUSER/raspi-nextcloud-setup.git"
REPO_DIR="/opt/raspi-nextcloud-setup"
LOG_DIR="/var/log/raspi-nextcloud"
LOG_FILE="$LOG_DIR/bootstrap.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Bootstrapper: raspi-nextcloud-setup ==="

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
   echo "Please run as root: sudo bash -c \"$(< /proc/self/fd/0)\""
   exit 1
fi

command -v apt-get >/dev/null || { echo "This script expects Debian/Raspbian (apt-get)."; exit 1; }

echo "[1/3] Ensuring git is installed..."
apt-get update -y
apt-get install -y git ca-certificates curl

echo "[2/3] Getting repository..."
if [[ -d "$REPO_DIR/.git" ]]; then
  git -C "$REPO_DIR" fetch --all --prune
  git -C "$REPO_DIR" reset --hard origin/main
else
  rm -rf "$REPO_DIR"
  git clone "$REPO_URL" "$REPO_DIR"
fi

chmod +x "$REPO_DIR/setup.sh"

echo "[3/3] Running setup..."
exec "$REPO_DIR/setup.sh"
