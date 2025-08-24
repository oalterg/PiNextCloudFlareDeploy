#!/bin-bash
# install.sh — idempotent and robust bootstrapper for raspi-nextcloud-setup

set -Eeuo pipefail

REPO_DIR="/opt/raspi-nextcloud-setup"
LOG_DIR="/var/log/raspi-nextcloud"
LOG_FILE="$LOG_DIR/bootstrap.log"
LOCK_FILE="/var/run/raspi-nextcloud-install.lock"

# --- Pre-flight Checks ---
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
   echo "This script must be run as root. Please use 'sudo'."
   exit 1
fi

# --- Logging and Locking ---
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# Non-blocking lock to prevent concurrent execution
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "Another installation is already running. Aborting."; exit 1; }
# The lock will be released automatically when the script exits.

echo "=== Bootstrapper Started: $(date) ==="

# --- Dependency Installation ---
echo "[1/3] Ensuring core dependencies are installed..."
if ! command -v apt-get >/dev/null; then
    echo "This script requires a Debian-based OS (using apt-get). Aborting."
    exit 1
fi
apt-get update -y
apt-get install -y git ca-certificates curl

# --- Repository Management ---
echo "[2/3] Cloning/updating the repository in $REPO_DIR..."
if [[ -d "$REPO_DIR/.git" ]]; then
  echo "Repository exists. Fetching updates and resetting to origin/main..."
  git -C "$REPO_DIR" fetch --all --prune
  git -C "$REPO_DIR" reset --hard origin/main
else
  echo "Cloning repository..."
  rm -rf "$REPO_DIR"
  git clone "https://github.com/oalterg/pinextcloudflaredeploy.git" "$REPO_DIR"
fi

chmod +x "$REPO_DIR/setup.sh"

# --- Handoff to Setup Script ---
echo "[3/3] Handing off to the main setup script..."
# 'exec' replaces the current process with the setup script
exec "$REPO_DIR/setup.sh"
