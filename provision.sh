#!/bin/bash
set -euo pipefail

# --- Configuration ---
APP_DIR="/opt/appliance-manager"
REPO_DIR="/opt/raspi-nextcloud-setup"
BOOT_CONFIG="/boot/firmware/factory_config.txt"
SERVICE_FILE="/etc/systemd/system/appliance-manager.service"
RASPI_CLOUD_SCRIPT="/usr/local/sbin/raspi-cloud"
# Base URL for updates (matches the install script source)
UPDATE_BASE_URL="https://raw.githubusercontent.com/oalterg/pinextcloudflaredeploy/main"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
err() { echo -e "${RED}[ERROR] $1${NC}"; }

# --- 1. Input Validation ---
if [[ $EUID -ne 0 ]]; then
   err "This script must be run as root."
   exit 1
fi

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <NEWT_ID> <NEWT_SECRET> <NC_DOMAIN> <HA_DOMAIN> <PANGOLIN_ENDPOINT>"
    exit 1
fi

# Sanitize inputs
NEWT_ID="$1"
NEWT_SECRET="$2"
NC_DOMAIN="$3"
HA_DOMAIN="$4"
PANGOLIN_ENDPOINT="$5"

# --- 2. Install System Dependencies ---
log "Installing Python and Flask dependencies..."
apt-get update -qq
apt-get install -y python3-flask python3-dotenv python3-pip jq moreutils pwgen git parted curl

# --- 3. Setup Manufacturing Artifact (Factory Config) ---
log "Writing factory configuration to $BOOT_CONFIG..."
mkdir -p "$(dirname "$BOOT_CONFIG")"

cat > "$BOOT_CONFIG" <<EOF
NEWT_ID=${NEWT_ID}
NEWT_SECRET=${NEWT_SECRET}
NC_DOMAIN=${NC_DOMAIN}
HA_DOMAIN=${HA_DOMAIN}
PANGOLIN_ENDPOINT=${PANGOLIN_ENDPOINT}
EOF
chmod 600 "$BOOT_CONFIG" || true

# --- 4. Setup Appliance Manager Application ---
log "Deploying Python Web Controller to $APP_DIR..."
mkdir -p "$APP_DIR/templates"

# Write app.py
# CRITICAL: Use 'EOF' (quoted) to prevent shell from expanding $2 inside awk commands
cat > "$APP_DIR/app.py" <<'EOF'
import os
import time
import shutil
import secrets
import string
import subprocess
import threading
import json
import hashlib
import logging
import shlex
from flask import Flask, render_template, jsonify, request

app = Flask(__name__)

# --- Configuration & Constants ---
FACTORY_CONFIG = "/boot/firmware/factory_config.txt"
REPO_DIR = "/opt/raspi-nextcloud-setup"
ENV_FILE = f"{REPO_DIR}/.env"
COMPOSE_FILE = f"{REPO_DIR}/docker-compose.yml"
LOG_DIR = "/var/log/raspi-nextcloud"
BACKUP_DIR = "/mnt/backup" 
RASPI_CLOUD_BIN = "/usr/local/sbin/raspi-cloud"
CRON_FILE = "/etc/cron.d/nextcloud-backup"
PROVISION_SCRIPT = f"{REPO_DIR}/provision.sh"
# Placeholder: We will inject the actual URL using sed in the provision script
UPDATE_URL = "${UPDATE_BASE_URL}/provision.sh"

LOG_FILES = {
    "setup": f"{LOG_DIR}/main_setup.log",
    "backup": f"{LOG_DIR}/backup.log",
    "restore": f"{LOG_DIR}/restore.log",
    "update": f"{LOG_DIR}/manager_update.log"
}

task_lock = threading.Lock()
current_task_status = {"status": "idle", "message": "", "log_type": "setup"}

# --- Helpers ---
def run_background_task(task_name, command, log_type):
    global current_task_status
    with task_lock:
        current_task_status = {"status": "running", "message": f"{task_name} in progress...", "log_type": log_type}
    
    try:
        # Redirect stderr to stdout to capture errors in logs
        subprocess.run(command, shell=True, check=True)
        with task_lock:
            current_task_status["status"] = "success"
            current_task_status["message"] = f"{task_name} completed successfully."
    except subprocess.CalledProcessError as e:
        with task_lock:
            current_task_status["status"] = "error"
            current_task_status["message"] = f"{task_name} failed. Check logs."
    except Exception as e:
        with task_lock:
            current_task_status["status"] = "error"
            current_task_status["message"] = str(e)
    
    time.sleep(10)
    if current_task_status["status"] != "running":
        current_task_status["status"] = "idle"

def get_factory_config():
    config = {}
    if os.path.exists(FACTORY_CONFIG):
        with open(FACTORY_CONFIG, 'r') as f:
            for line in f:
                if '=' in line:
                    key, value = line.strip().split('=', 1)
                    config[key] = value.strip()
    return config

def get_env_config():
    config = {}
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE, 'r') as f:
            for line in f:
                if '=' in line:
                    key, value = line.strip().split('=', 1)
                    config[key] = value.strip()
    return config

def update_env_var(key, value):
    try:
        rc = subprocess.call(f"grep -q '^{key}=' {ENV_FILE}", shell=True)
        if rc == 0:
            subprocess.run(["sed", "-i", f"s|^{key}=.*|{key}={value}|", ENV_FILE])
        else:
            with open(ENV_FILE, "a") as f:
                f.write(f"\n{key}={value}")
        return True
    except:
        return False

def is_setup_complete():
    return os.path.exists(f"{REPO_DIR}/.setup_complete")

def calculate_sha256(filepath):
    sha256_hash = hashlib.sha256()
    with open(filepath, "rb") as f:
        for byte_block in iter(lambda: f.read(4096), b""):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest()

# --- Routes: Main UI ---
@app.route('/')
def index():
    if not is_setup_complete():
        return render_template('installing.html')

    factory = get_factory_config()
    env = get_env_config()
    
    is_custom = env.get('PANGOLIN_ENDPOINT') != factory.get('PANGOLIN_ENDPOINT')
        
    return render_template('dashboard.html', 
                         nc_domain=env.get('NEXTCLOUD_TRUSTED_DOMAINS'), 
                         ha_domain=env.get('HA_TRUSTED_DOMAINS'),
                         creds={"user": env.get('NEXTCLOUD_ADMIN_USER'), "pass": env.get('NEXTCLOUD_ADMIN_PASSWORD')},
                         tunnel={"factory": factory, "current": env, "is_custom": is_custom})

# --- Routes: API Status ---
@app.route('/api/status')
def system_status():
    services = {"nextcloud": "stopped", "db": "stopped", "homeassistant": "missing", "newt": "stopped"}
    try:
        # Docker Services Check
        out = subprocess.check_output(f"docker compose -f {COMPOSE_FILE} ps --format '{{{{.Service}}}}:{{{{.State}}}}:{{{{.Health}}}}'", shell=True).decode()
        for line in out.splitlines():
            parts = line.split(':')
            if len(parts) >= 2:
                svc = parts[0]
                state = parts[1]
                health = parts[2] if len(parts) > 2 else ""
                status = "running" if "running" in state else "stopped"
                if "unhealthy" in health: status = "unhealthy"
                elif "starting" in health: status = "starting"
                if svc in services: services[svc] = status

        # Maintenance Mode Check
        try:
            m_check = subprocess.check_output(f"docker compose -f {COMPOSE_FILE} exec -u www-data nextcloud php occ maintenance:mode", shell=True).decode()
            services['maintenance_mode'] = 'enabled' if 'enabled' in m_check else 'disabled'
        except: services['maintenance_mode'] = 'unknown'

        # System Resources Stats (CPU/RAM/Root Disk)
        try:
            # Load Avg (1 min)
            load1, _, _ = os.getloadavg()
            services['cpu_load'] = round(load1, 2)
            
            # RAM
            # Because we used quoted EOF, $2 and $3 are preserved literally for awk here:
            mem_info = subprocess.check_output("free -m | awk '/Mem:/ {print $2 \" \" $3}'", shell=True).decode().split()
            if len(mem_info) == 2:
                total_mem = int(mem_info[0])
                used_mem = int(mem_info[1])
                services['ram_percent'] = round((used_mem / total_mem) * 100, 1)
                services['ram_text'] = f"{used_mem}MB / {total_mem}MB"

            # Root Disk
            total, used, free = shutil.disk_usage("/")
            services['root_total_gb'] = round(total / (1024**3), 1)
            services['root_free_gb'] = round(free / (1024**3), 1)
            services['root_percent'] = round((used / total) * 100, 1)

        except Exception as e:
            services['sys_error'] = str(e)

    except Exception as e: return jsonify({"error": str(e)}), 500
    return jsonify(services)

@app.route('/api/task_status')
def get_task_status():
    return jsonify(current_task_status)

@app.route('/api/logs/<log_target>')
def get_logs(log_target):
    # If target is in our known file list, read the file
    if log_target in LOG_FILES:
        filepath = LOG_FILES[log_target]
        if os.path.exists(filepath):
            return subprocess.check_output(["tail", "-n", "100", filepath]).decode()
        return "Log file empty or not found."
    
    # Otherwise, assume it is a docker service name
    try:
        # Security: Allow only alphanumeric service names
        if not log_target.isalnum(): return "Invalid service name."
        
        # Use docker compose logs
        cmd = f"docker compose -f {COMPOSE_FILE} logs --tail=100 {log_target}"
        output = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT).decode()
        return output
    except subprocess.CalledProcessError:
        return "Failed to fetch docker logs. Service might not be running."
    except Exception as e:
        return f"Error: {str(e)}"

# --- Routes: Drives & Storage ---
@app.route('/api/drives')
def list_drives():
    try:
        root_dev = subprocess.check_output("findmnt -n -o SOURCE /", shell=True).decode().strip()
        if "mmcblk" in root_dev: root_disk = root_dev.split('p')[0]
        else: root_disk = root_dev.strip('0123456789')
        
        output = subprocess.check_output("lsblk -J -d -o NAME,SIZE,TYPE,MODEL,RM", shell=True).decode()
        data = json.loads(output)
        
        # Check explicit mount point for backup
        backup_mount_source = ""
        try:
            # Returns e.g. /dev/sda1
            backup_mount_source = subprocess.check_output(f"findmnt -n -o SOURCE {BACKUP_DIR} || true", shell=True).decode().strip()
        except: pass

        candidates = []
        for dev in data['blockdevices']:
            dev_name = f"/dev/{dev['name']}"
            if dev['type'] != 'disk': continue
            if dev_name in root_disk or root_disk in dev_name: continue
            
            # Robust check: Is this drive (or a partition on it) mounted at /mnt/backup?
            is_backup = False
            if backup_mount_source and dev_name in backup_mount_source:
                is_backup = True
            
            candidates.append({
                "path": dev_name,
                "size": dev['size'],
                "model": dev.get('model', 'Unknown'),
                "is_backup": is_backup
            })
            
        return jsonify(candidates)
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/api/drives/format', methods=['POST'])
def format_drive():
    if current_task_status["status"] == "running": return jsonify({"error": "Task running"}), 409
    
    drive_path = request.json.get('path')
    if not drive_path or "mmcblk" in drive_path: 
        return jsonify({"error": "Invalid drive"}), 400

    # Escaped \$UUID and \$(blkid) are NO LONGER NEEDED with quoted EOF, 
    # but we must use standard string concatenation or f-strings in Python carefully.
    # Since this is inside Python code string, we just write valid Python.
    # Note: The 'cmd' variable below is a Python string being sent to subprocess.
    # We must ensure the SHELL (inside subprocess) sees the right variables.
    
    cmd = (
        f"umount {drive_path}* || true; "
        f"wipefs -a {drive_path}; "
        f"mkfs.ext4 -F -L 'NextcloudBackup' {drive_path}; "
        f"mkdir -p {BACKUP_DIR}; "
        f"UUID=$(blkid -o value -s UUID {drive_path}); "  # Removed backslash before $
        f"sed -i '\|{BACKUP_DIR}|d' /etc/fstab; "
        f"echo \"UUID=$UUID {BACKUP_DIR} ext4 defaults,nofail 0 2\" >> /etc/fstab; " # Removed backslash before $
        f"mount -a;"
    )
    
    threading.Thread(target=run_background_task, args=("Format Drive", cmd, "setup")).start()
    return jsonify({"status": "started"})

# --- Routes: Backup Config & Stats ---
@app.route('/api/backup/stats')
def backup_stats():
    # Check if mounted
    if not os.path.ismount(BACKUP_DIR):
         return jsonify({"mounted": False, "free_gb": 0, "total_gb": 0, "percent": 0})
    
    try:
        total, used, free = shutil.disk_usage(BACKUP_DIR)
        return jsonify({
            "mounted": True,
            "free_gb": round(free / (1024**3), 2),
            "total_gb": round(total / (1024**3), 2),
            "used_gb": round(used / (1024**3), 2),
            "percent": round((used / total) * 100, 1)
        })
    except:
        return jsonify({"mounted": False, "error": "Disk check failed"})

@app.route('/api/backup/config', methods=['GET', 'POST'])
def backup_config():
    if request.method == 'GET':
        env = get_env_config()
        return jsonify({
            "retention": env.get("BACKUP_RETENTION", "8"),
            "hour": env.get("BACKUP_HOUR", "3"),
            "minute": env.get("BACKUP_MINUTE", "0"),
            "day_week": env.get("BACKUP_DAY_WEEK", "*"),
            "day_month": env.get("BACKUP_DAY_MONTH", "*")
        })
    
    # POST: Save Settings
    data = request.json
    retention = data.get('retention', '8')
    hour = data.get('hour', '3')
    minute = data.get('minute', '0')
    day_week = data.get('day_week', '*')
    day_month = data.get('day_month', '*')
    
    # Update .env for persistence
    update_env_var("BACKUP_RETENTION", retention)
    update_env_var("BACKUP_HOUR", hour)
    update_env_var("BACKUP_MINUTE", minute)
    update_env_var("BACKUP_DAY_WEEK", day_week)
    update_env_var("BACKUP_DAY_MONTH", day_month)
    
    # Update Cron File
    # Cron format: min hour dom month dow
    cron_line = f"{minute} {hour} {day_month} * {day_week} root {RASPI_CLOUD_BIN} --backup >> {LOG_FILES['backup']} 2>&1\n"
    try:
        with open(CRON_FILE, 'w') as f:
            f.write("# Generated by Appliance Manager\n")
            f.write(cron_line)
        return jsonify({"status": "success"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

# --- Routes: Backup & Restore Execution ---
@app.route('/api/backup/now', methods=['POST'])
def trigger_backup():
    if current_task_status["status"] == "running": return jsonify({"error": "Task running"}), 409
    
    strategy = request.json.get('strategy', 'full')
    
    if strategy == 'data_only':
        data_dir = get_env_config().get('NEXTCLOUD_DATA_DIR', '/home/admin/nextcloud')
        timestamp = time.strftime("%Y-%m-%d_%H-%M-%S")
        filename = f"{BACKUP_DIR}/nc_data_only_{timestamp}.tar.gz"
        cmd = (
            f"echo 'Starting Data-Only Backup...' >> {LOG_FILES['backup']}; "
            f"tar -czf {filename} -C {data_dir} . >> {LOG_FILES['backup']} 2>&1; "
            f"echo 'Data-Only Backup Complete: {filename}' >> {LOG_FILES['backup']}"
        )
        task_name = "Data-Only Backup"
    else:
        cmd = f"{RASPI_CLOUD_BIN} --backup >> {LOG_FILES['backup']} 2>&1"
        task_name = "Full System Backup"

    threading.Thread(target=run_background_task, args=(task_name, cmd, "backup")).start()
    return jsonify({"status": "started"})

@app.route('/api/backups/list')
def list_backups():
    backups = []
    if os.path.exists(BACKUP_DIR):
        for f in os.listdir(BACKUP_DIR):
            if f.endswith(".tar.gz"):
                path = os.path.join(BACKUP_DIR, f)
                try:
                    size = os.path.getsize(path) / (1024*1024)
                    btype = "Data Only" if "data_only" in f else "Full System"
                    backups.append({"name": f, "size": f"{size:.2f} MB", "type": btype})
                except: pass
    backups.sort(key=lambda x: x['name'], reverse=True)
    return jsonify(backups)

@app.route('/api/restore', methods=['POST'])
def trigger_restore():
    if current_task_status["status"] == "running": return jsonify({"error": "Task running"}), 409
    
    filename = request.json.get('filename')
    full_path = os.path.join(BACKUP_DIR, filename)
    
    if "data_only" in filename:
        data_dir = get_env_config().get('NEXTCLOUD_DATA_DIR', '/home/admin/nextcloud')
        cmd = (
            f"echo 'Restoring Data Only...' >> {LOG_FILES['restore']}; "
            f"tar -xzf {full_path} -C {data_dir} >> {LOG_FILES['restore']} 2>&1; "
            f"docker compose -f {COMPOSE_FILE} exec -u www-data nextcloud php occ files:scan --all >> {LOG_FILES['restore']} 2>&1"
        )
        task_name = "Data Restore"
    else:
        cmd = f"{RASPI_CLOUD_BIN} --restore {full_path} --no-prompt >> {LOG_FILES['restore']} 2>&1"
        task_name = "Full Restore"

    threading.Thread(target=run_background_task, args=(task_name, cmd, "restore")).start()
    return jsonify({"status": "started"})

# --- Routes: Tunnel Management ---
@app.route('/api/tunnel', methods=['POST'])
def update_tunnel():
    if current_task_status["status"] == "running": return jsonify({"error": "Task running"}), 409
    
    action = request.json.get('action')
    if action == 'revert':
        factory = get_factory_config()
        update_env_var('PANGOLIN_ENDPOINT', factory.get('PANGOLIN_ENDPOINT', ''))
        update_env_var('NEWT_ID', factory.get('NEWT_ID', ''))
        update_env_var('NEWT_SECRET', factory.get('NEWT_SECRET', ''))
    else:
        data = request.json
        update_env_var('PANGOLIN_ENDPOINT', data.get('endpoint'))
        update_env_var('NEWT_ID', data.get('id'))
        update_env_var('NEWT_SECRET', data.get('secret'))
    
    cmd = f"docker compose -f {COMPOSE_FILE} up -d --force-recreate newt"
    threading.Thread(target=run_background_task, args=("Tunnel Configuration", cmd, "setup")).start()
    return jsonify({"status": "started"})

# --- Routes: Maintenance & Updates ---
@app.route('/api/maintenance/mode', methods=['POST'])
def set_maintenance():
    mode = request.json.get('mode')
    flag = "--on" if mode == 'on' else "--off"
    try:
        subprocess.check_call(f"docker compose -f {COMPOSE_FILE} exec -u www-data nextcloud php occ maintenance:mode {flag}", shell=True)
        return jsonify({"status": "success"})
    except Exception as e: return jsonify({"error": str(e)}), 500

@app.route('/api/upgrade', methods=['POST'])
def trigger_upgrade():
    if current_task_status["status"] == "running": return jsonify({"error": "Task running"}), 409
    
    # Safe System Upgrade (Standard Updates Only, no Dist-Upgrade)
    cmd = (
        "echo 'Starting System Update...' > " + LOG_FILES['setup'] + "; "
        "export DEBIAN_FRONTEND=noninteractive; "
        "apt-get update >> " + LOG_FILES['setup'] + " 2>&1; "
        "apt-get upgrade -y >> " + LOG_FILES['setup'] + " 2>&1; "
        "echo 'Updating Docker Containers...' >> " + LOG_FILES['setup'] + "; "
        f"cd {REPO_DIR} && docker compose pull >> " + LOG_FILES['setup'] + " 2>&1 && "
        "docker compose up -d >> " + LOG_FILES['setup'] + " 2>&1"
    )
    threading.Thread(target=run_background_task, args=("System Upgrade", cmd, "setup")).start()
    return jsonify({"status": "started"})

@app.route('/api/manager/check_update', methods=['GET'])
def check_manager_update():
    try:
        temp_file = "/tmp/provision.sh.new"
        subprocess.check_call(f"curl -fsSL {UPDATE_URL} -o {temp_file}", shell=True)
        
        if not os.path.exists(PROVISION_SCRIPT):
            return jsonify({"available": True, "message": "Current script missing"})

        current_hash = calculate_sha256(PROVISION_SCRIPT)
        new_hash = calculate_sha256(temp_file)
        
        if current_hash != new_hash:
            return jsonify({"available": True, "message": "New version available"})
        else:
            return jsonify({"available": False, "message": "Manager is up to date"})
            
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/api/manager/update', methods=['POST'])
def do_manager_update():
    if current_task_status["status"] == "running": return jsonify({"error": "Task running"}), 409

    if not os.path.exists(FACTORY_CONFIG):
         return jsonify({"error": "Factory config missing, cannot re-provision safely"}), 500

    # Retrieve existing factory config via Python to safely pass to the new script.
    # We avoid relying on shell 'source' which can fail to export variables to child processes.
    config = get_factory_config()
    
    # Prepare arguments using shlex.quote to prevent shell injection/corruption
    args = [
        config.get('NEWT_ID', ''),
        config.get('NEWT_SECRET', ''),
        config.get('NC_DOMAIN', ''),
        config.get('HA_DOMAIN', ''),
        config.get('PANGOLIN_ENDPOINT', '')
    ]
    safe_args = " ".join([shlex.quote(a) for a in args])

    cmd = (
        f"echo 'Updating Device Manager...' > {LOG_FILES['update']}; "
        f"curl -fsSL {UPDATE_URL} -o {PROVISION_SCRIPT} >> {LOG_FILES['update']} 2>&1; "
        f"chmod +x {PROVISION_SCRIPT}; "
        f"bash {PROVISION_SCRIPT} {safe_args} >> {LOG_FILES['update']} 2>&1; "
        "systemctl restart appliance-manager"
    )
    
    # We fire and forget this specific thread because the restart will kill the app
    threading.Thread(target=lambda: subprocess.run(cmd, shell=True)).start()
    return jsonify({"status": "started", "message": "Manager updating. Service will restart momentarily."})


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)
EOF

# Manually inject the Shell Variable into the python file using sed
sed -i "s|\${UPDATE_BASE_URL}|${UPDATE_BASE_URL}|g" "$APP_DIR/app.py"

# --- 5. Write Dashboard Templates ---
cat > "$APP_DIR/templates/dashboard.html" <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Device Dashboard</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/water.css@2/out/dark.css">
    <style>
        body { max-width: 1000px; margin: 0 auto; padding: 20px; }
        .header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #444; padding-bottom: 10px; margin-bottom: 20px; }
        .status-badge { padding: 5px 10px; border-radius: 4px; font-weight: bold; text-transform: uppercase; font-size: 0.8em; }
        .status-running { background: #2ecc71; color: #000; }
        .status-stopped { background: #e74c3c; color: #fff; }
        .status-unknown { background: #95a5a6; color: #000; }
        .tabs { display: flex; gap: 10px; margin-bottom: 20px; border-bottom: 1px solid #333; padding-bottom: 10px; }
        .tab-btn { background: #222; border: none; padding: 10px 20px; cursor: pointer; color: #ccc; border-radius: 5px 5px 0 0; }
        .tab-btn.active { background: #2196F3; color: white; }
        .tab-content { display: none; }
        .tab-content.active { display: block; animation: fadeIn 0.3s; }
        .card { background: #252525; padding: 20px; border-radius: 8px; margin-bottom: 15px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; }
        .log-box { background: #000; color: #0f0; font-family: monospace; height: 300px; overflow-y: scroll; padding: 10px; border-radius: 4px; font-size: 12px; }
        @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
        .drive-row { display: flex; justify-content: space-between; align-items: center; background: #333; padding: 10px; margin-bottom: 5px; border-radius: 4px; }
        
        /* Progress Bar */
        .progress-bg { background: #444; height: 20px; border-radius: 10px; overflow: hidden; margin-top: 5px; position: relative; }
        .progress-fill { background: #2ecc71; height: 100%; width: 0%; transition: width 0.5s; }
        .progress-text { position: absolute; width: 100%; text-align: center; top: 0; font-size: 12px; line-height: 20px; text-shadow: 1px 1px 2px #000; }
        
        .stat-item { display: flex; justify-content: space-between; margin-bottom: 5px; font-size: 0.9em; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Device Manager</h1>
        <div id="global-status">System Active</div>
    </div>

    <div class="tabs">
        <button class="tab-btn active" onclick="openTab('status')">Status</button>
        <button class="tab-btn" onclick="openTab('backup')">Backup & Storage</button>
        <button class="tab-btn" onclick="openTab('config')">Config & Tunnel</button>
        <button class="tab-btn" onclick="openTab('logs')">Logs</button>
    </div>

    <div id="status" class="tab-content active">
        <div class="grid">
            <div class="card">
                <h3>Services</h3>
                <p>Nextcloud: <span id="st-nc" class="status-badge status-unknown">...</span></p>
                <p>Database: <span id="st-db" class="status-badge status-unknown">...</span></p>
                <p>Tunnel: <span id="st-newt" class="status-badge status-unknown">...</span></p>
                {% if ha_domain %}
                <p>Home Assistant: <span id="st-ha" class="status-badge status-unknown">...</span></p>
                {% endif %}
                <div style="margin-top:15px;">
                    <a href="https://{{ nc_domain }}" target="_blank"><button>Open Nextcloud</button></a>
                    {% if ha_domain %}
                    <a href="https://{{ ha_domain }}" target="_blank"><button>Open Home Assistant</button></a>
                    {% endif %}
                </div>
            </div>
            
            <div class="card">
                <h3>System Resources</h3>
                <div class="stat-item"><span>CPU Load:</span> <span id="sys-cpu">...</span></div>
                <div class="stat-item"><span>RAM Usage:</span> <span id="sys-ram">...</span></div>
                
                <h4 style="margin-top: 15px; margin-bottom: 5px;">Root Filesystem</h4>
                <div class="progress-bg">
                    <div class="progress-fill" id="root-bar"></div>
                    <div class="progress-text" id="root-text">Checking...</div>
                </div>
            </div>

            <div class="card">
                <h3>Maintenance</h3>
                <p>Mode: <span id="st-maint">Checking...</span></p>
                <button onclick="toggleMaintenance('on')">Enable Maint. Mode</button>
                <button onclick="toggleMaintenance('off')">Disable Maint. Mode</button>
                <hr>
                <h3>Updates</h3>
                <button onclick="triggerAction('/api/upgrade', 'System Upgrade')">System OS Upgrade</button>
                <div style="margin-top: 10px;">
                     <button id="btn-check-update" onclick="checkManagerUpdate()">Check App Update</button>
                     <button id="btn-do-update" onclick="doManagerUpdate()" style="display:none; background-color: #2ecc71; color: black;">Update Manager Now</button>
                     <span id="update-msg" style="font-size: 0.8em; margin-left: 10px;"></span>
                </div>
            </div>
        </div>
    </div>

    <div id="logs" class="tab-content">
        <div class="card">
            <h3>System & Service Logs</h3>
            <div style="display:flex; gap:10px; margin-bottom: 10px;">
                <select id="log-selector" onchange="changeLogSource(this.value)">
                    <optgroup label="System Logs">
                        <option value="setup">Setup Log</option>
                        <option value="backup">Backup Log</option>
                        <option value="restore">Restore Log</option>
                        <option value="update">Manager Update Log</option>
                    </optgroup>
                    <optgroup label="Service Containers">
                        <option value="nextcloud">Nextcloud Container</option>
                        <option value="db">Database Container</option>
                        <option value="homeassistant">Home Assistant Container</option>
                        <option value="newt">Tunnel (Newt) Container</option>
                    </optgroup>
                </select>
                <button onclick="pollLogs()">Refresh</button>
            </div>
            <div id="console-output" class="log-box">Select a log source...</div>
        </div>
    </div>

    <div id="backup" class="tab-content">
        <div class="grid">
            <div class="card">
                <h3>Drive Management</h3>
                <p>Manage external storage.</p>
                <div id="drive-list">Loading drives...</div>
                <button onclick="loadDrives()">Refresh Drives</button>
                
                <h4 style="margin-top: 20px">Backup Drive Usage</h4>
                <div id="disk-stats">
                    <div class="progress-bg">
                        <div class="progress-fill" id="disk-bar"></div>
                        <div class="progress-text" id="disk-text">Not Mounted</div>
                    </div>
                </div>
            </div>

            <div class="card">
                <h3>Backup Settings</h3>
                <form onsubmit="saveBackupConfig(event)">
                    <label>Retention (Snapshots to keep):</label>
                    <input type="number" id="bk-retention" min="1" max="50">
                    
                    <label>Frequency:</label>
                    <select id="bk-freq" onchange="updateFreqUI()">
                        <option value="daily">Daily</option>
                        <option value="weekly">Weekly</option>
                        <option value="monthly">Monthly</option>
                    </select>

                    <div id="ui-dow" style="display:none;">
                        <label>Day of Week:</label>
                        <select id="bk-dow">
                            <option value="0">Sunday</option>
                            <option value="1">Monday</option>
                            <option value="2">Tuesday</option>
                            <option value="3">Wednesday</option>
                            <option value="4">Thursday</option>
                            <option value="5">Friday</option>
                            <option value="6">Saturday</option>
                        </select>
                    </div>

                    <div id="ui-dom" style="display:none;">
                        <label>Day of Month:</label>
                        <input type="number" id="bk-dom" min="1" max="31" value="1">
                    </div>

                    <label>Time (24h):</label>
                    <div style="display: flex; gap: 10px;">
                        <select id="bk-hour" style="flex:1"></select>
                        <select id="bk-min" style="flex:1">
                            <option value="0">00</option>
                            <option value="15">15</option>
                            <option value="30">30</option>
                            <option value="45">45</option>
                        </select>
                    </div>
                    <button type="submit" style="margin-top: 10px;">Save Settings</button>
                </form>

                <hr>
                <h4>Trigger Manual Backup</h4>
                <select id="backup-strategy">
                    <option value="full">Full System (Recommended)</option>
                    <option value="data_only">Nextcloud Data Only (Faster)</option>
                </select>
                <button onclick="runBackup()">Run Backup Now</button>
            </div>
        </div>
        
        <div class="card">
            <h3>Restore</h3>
            <p>Select a backup file to restore. <strong>Warning: Overwrites existing data.</strong></p>
            <select id="backup-list" style="width: 100%; margin-bottom: 10px;"></select>
            <button style="background-color: #e74c3c;" onclick="confirmRestore()">Restore Selected</button>
        </div>
    </div>

    <div id="config" class="tab-content">
        <div class="card" style="border-left: 5px solid #e74c3c;">
            <h3>Credentials</h3>
            <p><strong>User:</strong> {{ creds.user }}</p>
            <p><strong>Pass:</strong> {{ creds.pass }}</p>
        </div>
        <div class="card">
            <h3>Pangolin Tunnel Connection</h3>
            <p>
                Current Status: 
                {% if tunnel.is_custom %}
                    <strong style="color: #e67e22">CUSTOM CONFIGURATION</strong>
                {% else %}
                    <strong style="color: #2ecc71">FACTORY DEFAULT</strong>
                {% endif %}
            </p>
            
            <form onsubmit="updateTunnel(event)">
                <label>Endpoint:</label>
                <input type="text" id="tun-ep" value="{{ tunnel.current.PANGOLIN_ENDPOINT }}">
                <label>ID:</label>
                <input type="text" id="tun-id" value="{{ tunnel.current.NEWT_ID }}">
                <label>Secret:</label>
                <input type="password" id="tun-sec" value="{{ tunnel.current.NEWT_SECRET }}">
                <button type="submit">Save & Restart Tunnel</button>
            </form>
            
            {% if tunnel.is_custom %}
            <hr>
            <button style="background-color: #e74c3c;" onclick="revertTunnel()">Revert to Factory Settings</button>
            {% endif %}
        </div>
    </div>

    <script>
        let currentLogSource = 'setup';

        function init() {
            // Populate Hours
            const hourSel = document.getElementById('bk-hour');
            for(let i=0; i<24; i++) {
                let opt = document.createElement('option');
                opt.value = i;
                opt.innerText = i.toString().padStart(2, '0') + ':00';
                hourSel.appendChild(opt);
            }
            
            setInterval(fetchStatus, 5000);
            setInterval(pollTask, 2000);
            // Poll logs only if on logs tab
            setInterval(() => {
                if(document.getElementById('logs').classList.contains('active')) pollLogs();
            }, 3000);
            
            fetchStatus();
        }

        function openTab(id) {
            document.querySelectorAll('.tab-content').forEach(d => d.classList.remove('active'));
            document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
            document.getElementById(id).classList.add('active');
            event.target.classList.add('active');
            
            if(id === 'backup') { 
                loadDrives(); 
                loadBackups(); 
                loadBackupConfig();
                loadDiskStats();
            }
            if(id === 'logs') {
                pollLogs();
            }
        }

        async function fetchStatus() {
            try {
                const res = await fetch('/api/status');
                const data = await res.json();
                
                // Services
                ['nc','db','ha','newt'].forEach(k => {
                    if(document.getElementById('st-'+k)) setStatus('st-'+k, data[k === 'nc' ? 'nextcloud' : (k==='newt'?'newt':(k==='ha'?'homeassistant':'db'))]);
                });
                if(document.getElementById('st-maint')) document.getElementById('st-maint').innerText = (data.maintenance_mode || 'unknown').toUpperCase();

                // Stats
                if(data.cpu_load !== undefined) document.getElementById('sys-cpu').innerText = data.cpu_load;
                if(data.ram_text !== undefined) document.getElementById('sys-ram').innerText = data.ram_text + " (" + data.ram_percent + "%)";
                
                // Root Disk
                if(data.root_percent !== undefined) {
                    const bar = document.getElementById('root-bar');
                    bar.style.width = data.root_percent + '%';
                    bar.style.backgroundColor = data.root_percent > 85 ? '#e74c3c' : '#2ecc71';
                    document.getElementById('root-text').innerText = data.root_percent + "% Used (" + data.root_free_gb + " GB Free)";
                }

            } catch(e) {}
        }

        function setStatus(elId, status) {
            const el = document.getElementById(elId);
            if(!el) return;
            el.className = 'status-badge status-' + (status || 'unknown');
            el.innerText = (status || 'unknown').toUpperCase();
        }

        async function loadDrives() {
            const el = document.getElementById('drive-list');
            el.innerHTML = 'Scanning...';
            try {
                const res = await fetch('/api/drives');
                const drives = await res.json();
                el.innerHTML = '';
                if(drives.length === 0) el.innerHTML = 'No external drives found.';
                drives.forEach(d => {
                    const div = document.createElement('div');
                    div.className = 'drive-row';
                    
                    let label = '<span><strong>' + d.path + '</strong> (' + d.size + ')</span>';
                    
                    if(d.is_backup) {
                        div.innerHTML = label + '<span class="status-badge status-running">Active Backup Drive</span>';
                    } else {
                        const btn = document.createElement('button');
                        btn.innerText = "Format & Use";
                        btn.style.fontSize = "0.8em";
                        btn.style.padding = "5px";
                        btn.onclick = () => formatDrive(d.path);
                        div.innerHTML = label;
                        div.appendChild(btn);
                    }
                    el.appendChild(div);
                });
            } catch(e) { el.innerHTML = 'Error loading drives'; }
        }

        async function loadDiskStats() {
            try {
                const res = await fetch('/api/backup/stats');
                const d = await res.json();
                const bar = document.getElementById('disk-bar');
                const txt = document.getElementById('disk-text');
                
                if(d.mounted) {
                    bar.style.width = d.percent + '%';
                    txt.innerText = d.used_gb + ' GB Used / ' + d.total_gb + ' GB Total (' + d.free_gb + ' GB Free)';
                    bar.style.backgroundColor = d.percent > 90 ? '#e74c3c' : '#2ecc71';
                } else {
                    bar.style.width = '0%';
                    txt.innerText = 'Backup Drive Not Mounted';
                }
            } catch(e) {}
        }

        async function loadBackupConfig() {
            const res = await fetch('/api/backup/config');
            const d = await res.json();
            document.getElementById('bk-retention').value = d.retention;
            document.getElementById('bk-hour').value = d.hour;
            document.getElementById('bk-min').value = d.minute;
            
            // Logic for Frequency UI
            let freq = 'daily';
            if(d.day_week !== '*') {
                freq = 'weekly';
                document.getElementById('bk-dow').value = d.day_week;
            } else if(d.day_month !== '*') {
                freq = 'monthly';
                document.getElementById('bk-dom').value = d.day_month;
            }
            
            document.getElementById('bk-freq').value = freq;
            updateFreqUI();
        }

        function updateFreqUI() {
            const freq = document.getElementById('bk-freq').value;
            document.getElementById('ui-dow').style.display = freq === 'weekly' ? 'block' : 'none';
            document.getElementById('ui-dom').style.display = freq === 'monthly' ? 'block' : 'none';
        }

        async function saveBackupConfig(e) {
            e.preventDefault();
            const freq = document.getElementById('bk-freq').value;
            let dow = '*';
            let dom = '*';
            
            if(freq === 'weekly') dow = document.getElementById('bk-dow').value;
            if(freq === 'monthly') dom = document.getElementById('bk-dom').value;

            const body = {
                retention: document.getElementById('bk-retention').value,
                hour: document.getElementById('bk-hour').value,
                minute: document.getElementById('bk-min').value,
                day_week: dow,
                day_month: dom
            };
            
            const res = await fetch('/api/backup/config', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify(body)
            });
            if(res.ok) alert("Settings saved and scheduled.");
            else alert("Error saving settings.");
        }

        async function formatDrive(path) {
            if(confirm("DANGER: This will ERASE ALL DATA on " + path + ". Are you sure?")) {
                if(prompt("Type 'FORMAT' to confirm destruction of data on " + path) === "FORMAT") {
                    triggerAction('/api/drives/format', 'Format Drive', {path: path});
                }
            }
        }

        async function runBackup() {
            const strategy = document.getElementById('backup-strategy').value;
            triggerAction('/api/backup/now', 'Backup', {strategy: strategy});
        }

        async function loadBackups() {
            const res = await fetch('/api/backups/list');
            const list = await res.json();
            const sel = document.getElementById('backup-list');
            sel.innerHTML = '';
            list.forEach(b => {
                const opt = document.createElement('option');
                opt.value = b.name;
                opt.innerText = b.name + ' [' + b.type + '] (' + b.size + ')';
                sel.appendChild(opt);
            });
        }

        async function confirmRestore() {
            const file = document.getElementById('backup-list').value;
            if(!file) return;
            if(confirm("DANGER: Restore " + file + "? This will overwrite data.")) {
                triggerAction('/api/restore', 'Restore', {filename: file});
            }
        }

        async function updateTunnel(e) {
            e.preventDefault();
            const data = {
                endpoint: document.getElementById('tun-ep').value,
                id: document.getElementById('tun-id').value,
                secret: document.getElementById('tun-sec').value
            };
            if(confirm("Change tunnel settings? Device connection may be lost momentarily.")) {
                const res = await fetch('/api/tunnel', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(data)});
                if(res.ok) setTimeout(() => location.reload(), 5000);
            }
        }

        async function revertTunnel() {
            if(confirm("Revert to Factory Connection settings?")) {
                const res = await fetch('/api/tunnel', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({action:'revert'})});
                if(res.ok) setTimeout(() => location.reload(), 5000);
            }
        }

        async function triggerAction(endpoint, name, body={}) {
            try {
                const res = await fetch(endpoint, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify(body)
                });
                const data = await res.json();
                if(data.status === 'started') {
                    alert(name + " started.");
                    pollTask();
                } else {
                    alert("Error: " + (data.error || "Unknown"));
                }
            } catch(e) { alert("Request failed"); }
        }

        async function toggleMaintenance(mode) {
            await fetch('/api/maintenance/mode', {
                method: 'POST', 
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({mode: mode})
            });
            setTimeout(fetchStatus, 1000);
        }

        async function checkManagerUpdate() {
            const btn = document.getElementById('btn-check-update');
            const msg = document.getElementById('update-msg');
            const doBtn = document.getElementById('btn-do-update');
            
            btn.disabled = true;
            btn.innerText = "Checking...";
            msg.innerText = "";
            doBtn.style.display = "none";
            
            try {
                const res = await fetch('/api/manager/check_update');
                const data = await res.json();
                
                if (data.available) {
                    msg.innerText = data.message;
                    msg.style.color = "#2ecc71";
                    doBtn.style.display = "inline-block";
                } else {
                    msg.innerText = data.message;
                    msg.style.color = "#ccc";
                }
            } catch (e) {
                msg.innerText = "Check failed.";
                msg.style.color = "#e74c3c";
            } finally {
                btn.disabled = false;
                btn.innerText = "Check App Update";
            }
        }
        
        async function doManagerUpdate() {
            if(!confirm("Update Device Manager? The interface will restart.")) return;
            const res = await fetch('/api/manager/update', {method:'POST'});
            const data = await res.json();
            if(data.status === 'started') {
                 alert("Update started. The page will reload in 15 seconds.");
                 setTimeout(() => location.reload(), 15000);
            } else {
                 alert("Update failed: " + data.error);
            }
        }

        async function pollTask() {
            const res = await fetch('/api/task_status');
            const data = await res.json();
            const banner = document.getElementById('global-status');
            banner.innerText = data.status === 'idle' ? 'System Active' : data.message;
            banner.style.color = data.status === 'error' ? 'red' : (data.status === 'running' ? '#2196F3' : 'white');
            
            // Auto switch log view if setup is running
            if(data.log_type === 'setup' && data.status === 'running') currentLogSource = 'setup';
        }

        function changeLogSource(val) {
            currentLogSource = val;
            pollLogs();
        }

        async function pollLogs() {
            const res = await fetch('/api/logs/' + currentLogSource);
            const txt = await res.text();
            const div = document.getElementById('console-output');
            div.innerText = txt;
            div.scrollTop = div.scrollHeight;
        }
        
        init();
    </script>
</body>
</html>
EOF

# Restore "Welcome" and "Installing" templates (same as before)
cat > "$APP_DIR/templates/welcome.html" <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Device Setup</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/water.css@2/out/water.css">
</head>
<body>
    <h1>Welcome to Your Private Cloud</h1>
    <ul>
        <li><strong>ID:</strong> {{ config.NEWT_ID }}</li>
        <li><strong>Nextcloud:</strong> {{ config.NC_DOMAIN }}</li>
        {% if config.HA_DOMAIN %}
        <li><strong>Home Assistant:</strong> {{ config.HA_DOMAIN }}</li>
        {% endif %}
    </ul>
    <button onclick="startSetup()" id="btn">Initialize Device</button>
    <script>
        function startSetup(){
            document.getElementById('btn').disabled = true;
            document.getElementById('btn').innerText = "Starting...";
            fetch('/start_setup',{method:'POST'}).then(()=>window.location.reload());
        }
    </script>
</body>
</html>
EOF

cat > "$APP_DIR/templates/installing.html" <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Installing...</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/water.css@2/out/water.css">
</head>
<body>
    <h1>System Installation in Progress</h1>
    <p>Please do not unplug. This may take 15-20 minutes.</p>
    <pre id="logs" style="background:#222; color:#0f0; padding:10px; height:300px; overflow:auto; font-size: 12px;"></pre>
    <script>
        setInterval(() => {
            fetch('/api/logs/setup').then(r=>r.text()).then(t => {
                const logDiv = document.getElementById('logs');
                logDiv.innerText = t;
                logDiv.scrollTop = logDiv.scrollHeight;
                if(t.includes("Installation complete")) location.reload();
            });
        }, 2000);
    </script>
</body>
</html>
EOF

# --- 6. Configure Systemd Service ---
log "Configuring systemd service..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Raspi Cloud Appliance Manager
After=network.target

[Service]
User=root
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/python3 $APP_DIR/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable appliance-manager.service

log "Provisioning Complete. The device is ready to ship."
log "On next boot, the web interface will be available on port 80."