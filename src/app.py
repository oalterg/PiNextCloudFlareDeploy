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
import requests
from flask import Flask, render_template, jsonify, request, Response
import migration

app = Flask(__name__)

# --- Authentication ---
def check_auth(username, password):
    # Try .env first, fall back to factory if setup hasn't run
    env_pass = get_env_config().get('MANAGER_PASSWORD')
    if not env_pass:
        env_pass = get_factory_config().get('MANAGER_PASSWORD')
    return username == 'admin' and password == env_pass

def authenticate():
    return Response(
        'Access Denied. Please log in with your generated Admin Password.', 401,
        {'WWW-Authenticate': 'Basic realm="HomeBrain Manager Login"'})

@app.before_request
def auth_gate():
    # 1. Always allow static assets
    if request.endpoint == 'static':
        return
    
    # 2. Whitelist: Allow polling logs and fetching one-time credentials
    # This ensures the installing.html page doesn't break when the lock engages.
    if request.path in ['/api/logs/setup', '/api/setup/credentials']:
        return

    # 3. First Time Setup (Open Access)
    if not is_setup_complete():
        return

    # 4. Locked Mode (Require Authentication)
    auth = request.authorization
    if not auth or not check_auth(auth.username, auth.password):
        return authenticate()

@app.route("/api/setup/credentials")
def get_one_time_credentials():
    # Security: This file is created by deploy.sh and exists only briefly.
    creds_file = f"{INSTALL_DIR}/.install_creds.json"
    
    if os.path.exists(creds_file):
        try:
            with open(creds_file, "r") as f:
                data = json.load(f)
            # BURN AFTER READING: Delete immediately to prevent re-reading
            os.remove(creds_file)
            return jsonify(data)
        except Exception as e:
            return jsonify({"error": "Failed to read credentials"}), 500
    else:
        return jsonify({"error": "Credentials not available or already claimed"}), 404

# --- Configuration & Constants ---
FACTORY_CONFIG = "/boot/firmware/factory_config.txt"
HOMEBRAIN_ROOT = "/opt/homebrain"
INSTALL_DIR = HOMEBRAIN_ROOT # Alias for backward compatibility if needed
SETUP_STARTED_MARKER = f"{INSTALL_DIR}/.setup_started"
ENV_FILE = f"{INSTALL_DIR}/.env"
ENV_TEMPLATE = f"{INSTALL_DIR}/config/.env.template"
COMPOSE_FILE = f"{INSTALL_DIR}/docker-compose.yml"
OVERRIDE_FILE = f"{INSTALL_DIR}/docker-compose.override.yml"
LOG_DIR = "/var/log/homebrain"
BACKUP_DIR = "/mnt/backup"
RASPI_CLOUD_BIN = "/usr/local/sbin/raspi-cloud"
CRON_FILE = "/etc/cron.d/nextcloud-backup"
PROVISION_SCRIPT = f"{INSTALL_DIR}/scripts/provision.sh"
VERSION_FILE = f"{INSTALL_DIR}/version.json"
REPO_API_URL = "https://api.github.com/repos/oalterg/HomeBrain"
SCRIPT_UPDATE = f"{INSTALL_DIR}/scripts/update.sh"
SCRIPT_BACKUP = f"{INSTALL_DIR}/scripts/backup.sh"
SCRIPT_RESTORE = f"{INSTALL_DIR}/scripts/restore.sh"
SCRIPT_DEPLOY = f"{INSTALL_DIR}/scripts/deploy.sh"
SCRIPT_REDEPLOY = f"{INSTALL_DIR}/scripts/redeploy_tunnels.sh"
SCRIPT_UTILITIES = f"{INSTALL_DIR}/scripts/utilities.sh"
INSTALL_CREDS_PATH = f"{INSTALL_DIR}/install_creds.json"

LOG_FILES = {
    "setup": f"{LOG_DIR}/main_setup.log",
    "backup": f"{LOG_DIR}/backup.log",
    "restore": f"{LOG_DIR}/restore.log",
    "update": f"{LOG_DIR}/manager_update.log",
}

task_lock = threading.Lock()
current_task_status = {"status": "idle", "message": "", "log_type": "setup"}


# --- Helpers ---
def get_local_version():
    if os.path.exists(VERSION_FILE):
        try:
            with open(VERSION_FILE, "r") as f:
                return json.load(f)
        except:
            pass
    return {"channel": "unknown", "ref": "unknown", "updated_at": "unknown"}

def run_background_task(task_name, command, log_type):
    global current_task_status
    with task_lock:
        current_task_status = {
            "status": "running",
            "message": f"{task_name} in progress...",
            "log_type": log_type,
        }

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
        with open(FACTORY_CONFIG, "r") as f:
            for line in f:
                if "=" in line:
                    key, value = line.strip().split("=", 1)
                    config[key] = value.strip()
    return config


def get_env_config():
    config = {}
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE, "r") as f:
            for line in f:
                if "=" in line:
                    key, value = line.strip().split("=", 1)
                    config[key] = value.strip()
    return config


def update_env_var(key, value):
    try:
        # If value is None, remove the line
        if value is None:
            subprocess.run(["sed", "-i", f"/^{key}=/d", ENV_FILE])
            return True

        rc = subprocess.call(f"grep -q '^{key}=' {ENV_FILE}", shell=True)
        if rc == 0:
            # Use | delimiter for sed to handle complex strings
            safe_val = value.replace("|", "\\|")
            subprocess.run(["sed", "-i", f"s|^{key}=.*|{key}={safe_val}|", ENV_FILE])
        else:
            with open(ENV_FILE, "r+") as f:
                content = f.read()
                if content and not content.endswith("\n"):
                    f.write("\n")
            
            with open(ENV_FILE, "a") as f:
                f.write(f"{key}={value}\n")
        return True
    except:
        return False


def is_setup_complete():
    return os.path.exists(f"{INSTALL_DIR}/.setup_complete")


def is_setup_started():
    return os.path.exists(SETUP_STARTED_MARKER)


def calculate_sha256(filepath):
    sha256_hash = hashlib.sha256()
    with open(filepath, "rb") as f:
        for byte_block in iter(lambda: f.read(4096), b""):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest()


# --- Route: Trigger Initial Setup ---
@app.route("/start_setup", methods=["POST"])
def start_setup():
    if is_setup_complete():
        return jsonify({"error": "Setup already complete"}), 400

    # 1. Mark setup as started (prevents seeing welcome screen again)
    with open(SETUP_STARTED_MARKER, "w") as f:
        f.write(str(int(time.time())))

    # 2. Bootstrap .env file
    # Do not override env if redeploying, ensure we start from the robust template
    if not os.path.exists(ENV_FILE):
        if os.path.exists(ENV_TEMPLATE):
            shutil.copyfile(ENV_TEMPLATE, ENV_FILE)
        else:
            with open(ENV_FILE, "w") as f:
                f.write("# Auto-generated by HomeBrain Manager\n")
        # Harden: Ensure file is only readable by root
        os.chmod(ENV_FILE, 0o600)
        # Set Passwords & Critical Defaults
        update_env_var("NEXTCLOUD_DATA_DIR", "/home/admin/nextcloud")
        update_env_var("NEXTCLOUD_ADMIN_USER", "admin")


    # Map Factory Config to Environment Variables
    factory = get_factory_config()
    if "NEWT_ID" in factory:
        update_env_var("NEWT_ID", factory["NEWT_ID"])
    if "NEWT_SECRET" in factory:
        update_env_var("NEWT_SECRET", factory["NEWT_SECRET"])
    if "PANGOLIN_ENDPOINT" in factory:
        update_env_var("PANGOLIN_ENDPOINT", factory["PANGOLIN_ENDPOINT"])
    
    # Domain Logic: Main Domain -> Subdomains
    if "PANGOLIN_DOMAIN" in factory:
        main_dom = factory["PANGOLIN_DOMAIN"]
        update_env_var("PANGOLIN_DOMAIN", main_dom)
        update_env_var("MANAGER_DOMAIN", main_dom)
        update_env_var("NEXTCLOUD_TRUSTED_DOMAINS", f"nc.{main_dom}")
        update_env_var("HA_TRUSTED_DOMAINS", f"ha.{main_dom}")

    env_config = get_env_config()
    
    # 1. Migration Logic: Look for any existing password
    master_pass = (env_config.get('MASTER_PASSWORD') or 
                   env_config.get('NEXTCLOUD_ADMIN_PASSWORD') or 
                   env_config.get('MANAGER_PASSWORD'))
    
    # 2. Generation (if new install)
    if not master_pass:
        alphabet = string.ascii_letters + string.digits
        master_pass = ''.join(secrets.choice(alphabet) for _ in range(16))
    
    # 3. Write to install_creds.json for the Shell Scripts
    creds_data = {
        "username": "admin",
        "password": master_pass,
        "domain": env_config.get('PANGOLIN_DOMAIN'),
        "generated_at": time.time()
    }
    with open(INSTALL_CREDS_PATH, 'w') as f:
        json.dump(creds_data, f)

    # 4. Assign master password to all services
    update_env_var("MASTER_PASSWORD", master_pass)
    update_env_var("MANAGER_PASSWORD", master_pass)
    update_env_var("NEXTCLOUD_ADMIN_PASSWORD", master_pass)
    update_env_var("MYSQL_ROOT_PASSWORD", master_pass)
    update_env_var("MYSQL_PASSWORD", master_pass)
    update_env_var("HA_ADMIN_PASSWORD", master_pass)  

    # 4. Trigger deploy script in headless mode
    cmd = f"bash {SCRIPT_DEPLOY} >> {LOG_FILES['setup']} 2>&1"
    threading.Thread(
        target=run_background_task, args=("Initial Setup", cmd, "setup")
    ).start()
    return jsonify({"status": "started"})


# --- Route: Adopt Existing Drive ---
@app.route("/api/drives/mount", methods=["POST"])
def mount_drive():
    if current_task_status["status"] == "running":
        return jsonify({"error": "Task running"}), 409

    drive_path = request.json.get("path")
    if not drive_path or "mmcblk" in drive_path:
        return jsonify({"error": "Invalid drive"}), 400

    # 1. Determine the actual device/partition path to use
    target_path = drive_path
    
    # Check if this is a whole disk device (e.g., /dev/sda)
    # If it is a whole disk, append '1' to check the first partition (e.g., /dev/sda1)
    # This is a common convention, though 'p1' for NVMe/MMC can also occur.
    # The lsblk output in list_drives provides only whole disk paths, so we check for common partition suffixes.
    if not drive_path.endswith(('0','1','2','3','4','5','6','7','8','9')) and not drive_path.endswith('p'):
        # Try appending '1'
        target_path = drive_path + '1'
        
        # Verify if the partition actually exists
        if not os.path.exists(target_path):
             # For some systems (e.g., NVMe/MMC), the partition might be /dev/nvme0n1p1.
             # We rely on the user selecting the whole disk, so if /dev/sdX1 doesn't exist, we fallback
             # to trying the original whole-disk path, as it *might* have been formatted without partitions.
             target_path = drive_path
             
    # 2. Get UUID and FSType from the target path
    try:
        # Check UUID/FSType of the identified partition/device
        uuid_cmd = f"blkid -o value -s UUID {shlex.quote(target_path)}"
        fstype_cmd = f"blkid -o value -s TYPE {shlex.quote(target_path)}"

        uuid = subprocess.check_output(uuid_cmd, shell=True).decode().strip()
        fstype = subprocess.check_output(fstype_cmd, shell=True).decode().strip()

        if not uuid:
            # Fallback to the original whole-disk path if the partition check failed
            if target_path != drive_path:
                uuid = subprocess.check_output(f"blkid -o value -s UUID {shlex.quote(drive_path)}", shell=True).decode().strip()
                fstype = subprocess.check_output(f"blkid -o value -s TYPE {shlex.quote(drive_path)}", shell=True).decode().strip()
                if uuid:
                     target_path = drive_path # Use the whole disk path if it has a UUID
            
        if not uuid:
            # If still no UUID, it means the disk or its first partition is unformatted.
            return jsonify({"error": "No UUID found. Drive is likely unformatted or partitioned incorrectly."}), 400

        if fstype not in ["ext4", "ext3", "xfs"]:
            return jsonify({"error": f"Unsupported filesystem ({fstype})"}), 400
    except:
        return jsonify({"error": "Could not read drive info (blkid failed)"}), 500

    # 3. Use the discovered UUID and FSType to update fstab
    # We use target_path for unmounting but UUID for fstab entry.
    cmd = (
        f"umount {shlex.quote(target_path)} || true; "
        f"mkdir -p {BACKUP_DIR}; "
        # Remove any existing entry for the backup dir to avoid conflicts
        f"sed -i '\|{BACKUP_DIR}|d' /etc/fstab; "
        # Add new entry using the validated UUID
        f'echo "UUID={uuid} {BACKUP_DIR} {fstype} defaults,nofail 0 2" >> /etc/fstab; '
        f"mount -a"
    )

    threading.Thread(
        target=run_background_task, args=("Mount Existing Drive", cmd, "setup")
    ).start()
    return jsonify({"status": "started"})


# --- Routes: Main UI ---
@app.route("/")
def index():
    if not is_setup_complete():
        # Check dedicated marker file instead of log existence
        if is_setup_started():
            return render_template("installing.html")
        return render_template("welcome.html", config=get_factory_config())

    factory = get_factory_config()
    env = get_env_config()

    # Determine Tunnel Provider Mode
    # If any CF token exists, we are in Cloudflare mode
    cf_mode = bool(env.get("CF_TOKEN_NC") or env.get("CF_TOKEN_HA"))

    # Check if Pangolin is custom
    is_custom_pangolin = False
    if not cf_mode:
        # Check if critical tunnel params differ from factory
        is_custom_pangolin = (
            env.get("PANGOLIN_ENDPOINT") != factory.get("PANGOLIN_ENDPOINT") or
            env.get("PANGOLIN_DOMAIN") != factory.get("PANGOLIN_DOMAIN")
        )

    return render_template(
        "dashboard.html",
        main_domain=env.get("PANGOLIN_DOMAIN"),
        nc_domain=env.get("NEXTCLOUD_TRUSTED_DOMAINS"),
        ha_domain=env.get("HA_TRUSTED_DOMAINS"),
        manager_domain=env.get("MANAGER_DOMAIN"),
        tunnel={
            "factory": factory,
            "current": env,
            "mode": "cloudflare" if cf_mode else "pangolin",
            "is_custom_pangolin": is_custom_pangolin,
        },
    )


# --- Routes: API Status ---
@app.route("/api/status")
def system_status():
    services = {
        "nextcloud": "stopped",
        "db": "stopped",
        "homeassistant": "stopped",
        "tunnel": "stopped",
    }
    try:
        # Docker Services Check
        # Get profiles dynamically from common.sh for consistency
        profiles = subprocess.check_output(f"bash -c 'source {INSTALL_DIR}/scripts/common.sh; load_env; get_tunnel_profiles'", shell=True).decode().strip()

        compose_cmd = f"docker compose -f {COMPOSE_FILE} --env-file {ENV_FILE}"
        if os.path.exists(OVERRIDE_FILE):
            compose_cmd += f" -f {OVERRIDE_FILE}"
        compose_cmd += f" {profiles} ps --format '{{{{.Service}}}}:{{{{.State}}}}:{{{{.Health}}}}'"

        out = subprocess.check_output(compose_cmd, shell=True).decode()
        tunnel_status = "stopped"

        for line in out.splitlines():
            parts = line.split(":")
            if len(parts) >= 2:
                svc = parts[0]
                state = parts[1]
                health = parts[2] if len(parts) > 2 else ""

                status = "running" if "running" in state else "stopped"
                if "unhealthy" in health:
                    status = "unhealthy"
                elif "starting" in health:
                    status = "starting"

                if svc in services:
                    services[svc] = status

                # Consolidate Tunnel Status
                if svc == "newt" or svc.startswith("cloudflared"):
                    if status == "running":
                        tunnel_status = "running"

        services["tunnel"] = tunnel_status

        # Maintenance Mode Check
        try:
            m_check = subprocess.check_output(
                f"docker compose -f {COMPOSE_FILE} exec -u www-data nextcloud php occ maintenance:mode",
                shell=True,
            ).decode()
            services["maintenance_mode"] = (
                "enabled" if "enabled" in m_check else "disabled"
            )
        except:
            services["maintenance_mode"] = "unknown"

        # System Resources Stats (CPU/RAM/Root Disk)
        try:
            # CPU load
            def get_cpu_times():
                with open('/proc/stat') as f:
                    line = f.readline().strip()
                    fields = line.split()[1:]  # user nice system idle ...
                    return [int(x) for x in fields[:4]]  # user, nice, system, idle

            times1 = get_cpu_times()
            time.sleep(0.5)
            times2 = get_cpu_times()

            deltas = [t2 - t1 for t1, t2 in zip(times1, times2)]
            total_delta = sum(deltas)
            if total_delta == 0:
                cpu_load = 0.0
            else:
                idle_delta = deltas[3]
                used = total_delta - idle_delta
                cpu_load = round(100.0 * used / total_delta, 1)
            services["cpu_load"] = cpu_load

            # RAM
            # Because we used quoted EOF, $2 and $3 are preserved literally for awk here:
            mem_info = (
                subprocess.check_output(
                    "free -m | awk '/Mem:/ {print $2 \" \" $3}'", shell=True
                )
                .decode()
                .split()
            )
            if len(mem_info) == 2:
                total_mem = int(mem_info[0])
                used_mem = int(mem_info[1])
                services["ram_percent"] = round((used_mem / total_mem) * 100, 1)
                services["ram_text"] = f"{used_mem}MB / {total_mem}MB"

            # Root Disk
            total, used, free = shutil.disk_usage("/")
            services["root_total_gb"] = round(total / (1024**3), 1)
            services["root_free_gb"] = round(free / (1024**3), 1)
            services["root_percent"] = round((used / total) * 100, 1)

        except Exception as e:
            services["sys_error"] = str(e)

    except Exception as e:
        return jsonify({"error": str(e)}), 500
    return jsonify(services)


@app.route("/api/task_status")
def get_task_status():
    return jsonify(current_task_status)


@app.route("/api/logs/<log_target>")
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
        if not log_target.isalnum():
            return "Invalid service name."

        # Use docker compose logs
        cmd = f"docker compose -f {COMPOSE_FILE} logs --tail=100 {log_target}"
        output = subprocess.check_output(
            cmd, shell=True, stderr=subprocess.STDOUT
        ).decode()
        return output
    except subprocess.CalledProcessError:
        return "Failed to fetch docker logs. Service might not be running."
    except Exception as e:
        return f"Error: {str(e)}"


# --- Routes: Drives & Storage ---
@app.route("/api/drives")
def list_drives():
    try:
        root_dev = (
            subprocess.check_output("findmnt -n -o SOURCE /", shell=True)
            .decode()
            .strip()
        )
        if "mmcblk" in root_dev:
            root_disk = root_dev.split("p")[0]
        else:
            root_disk = root_dev.strip("0123456789")

        output = subprocess.check_output(
            "lsblk -J -d -o NAME,SIZE,TYPE,MODEL,RM", shell=True
        ).decode()
        data = json.loads(output)

        # Check explicit mount point for backup
        backup_mount_source = ""
        try:
            # Returns e.g. /dev/sda1
            backup_mount_source = (
                subprocess.check_output(
                    f"findmnt -n -o SOURCE {BACKUP_DIR} || true", shell=True
                )
                .decode()
                .strip()
            )
        except:
            pass

        candidates = []
        for dev in data["blockdevices"]:
            dev_name = f"/dev/{dev['name']}"
            
            # Filter out system pseudo-devices (zram, loop, ram)
            if dev["type"] != "disk":
                continue
            if dev_name.startswith("/dev/zram") or dev_name.startswith("/dev/loop") or dev_name.startswith("/dev/ram"):
                continue
                
            if dev_name in root_disk or root_disk in dev_name:
                continue

            # Robust check: Is this drive (or a partition on it) mounted at /mnt/backup?
            is_backup = False
            if backup_mount_source and dev_name in backup_mount_source:
                is_backup = True

            candidates.append(
                {
                    "path": dev_name,
                    "size": dev["size"],
                    "model": dev.get("model", "Unknown"),
                    "is_backup": is_backup,
                }
            )

        return jsonify(candidates)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/drives/format", methods=["POST"])
def format_drive():
    if current_task_status["status"] == "running":
        return jsonify({"error": "Task running"}), 409

    drive_path = request.json.get("path")
    if not drive_path or "mmcblk" in drive_path:
        return jsonify({"error": "Invalid drive"}), 400

    cmd = (
        f"umount {drive_path}* || true; "
        f"wipefs -a {drive_path}; "
        f"mkfs.ext4 -F -L 'NextcloudBackup' {drive_path}; "
        f"mkdir -p {BACKUP_DIR}; "
        f"UUID=$(blkid -o value -s UUID {drive_path}); "
        f"sed -i '\|{BACKUP_DIR}|d' /etc/fstab; "
        f'echo "UUID=$UUID {BACKUP_DIR} ext4 defaults,nofail 0 2" >> /etc/fstab; '
        f"mount -a;"
    )

    threading.Thread(
        target=run_background_task, args=("Format Drive", cmd, "setup")
    ).start()
    return jsonify({"status": "started"})


# --- Routes: Backup Config & Stats ---
@app.route("/api/backup/stats")
def backup_stats():
    # Check if mounted
    if not os.path.ismount(BACKUP_DIR):
        return jsonify({"mounted": False, "free_gb": 0, "total_gb": 0, "percent": 0})
    try:
        total, used, free = shutil.disk_usage(BACKUP_DIR)
        return jsonify(
            {
                "mounted": True,
                "free_gb": round(free / (1024**3), 2),
                "total_gb": round(total / (1024**3), 2),
                "used_gb": round(used / (1024**3), 2),
                "percent": round((used / total) * 100, 1),
            }
        )
    except:
        return jsonify({"mounted": False, "error": "Disk check failed"})


@app.route("/api/backup/config", methods=["GET", "POST"])
def backup_config():
    if request.method == "GET":
        env = get_env_config()
        return jsonify(
            {
                "retention": env.get("BACKUP_RETENTION", "8"),
                "hour": env.get("BACKUP_HOUR", "3"),
                "minute": env.get("BACKUP_MINUTE", "0"),
                "day_week": env.get("BACKUP_DAY_WEEK", "*"),
                "day_month": env.get("BACKUP_DAY_MONTH", "*"),
            }
        )

    # POST: Save Settings
    data = request.json
    retention = data.get("retention", "8")
    hour = data.get("hour", "3")
    minute = data.get("minute", "0")
    day_week = data.get("day_week", "*")
    day_month = data.get("day_month", "*")

    # Update .env for persistence
    update_env_var("BACKUP_RETENTION", retention)
    update_env_var("BACKUP_HOUR", hour)
    update_env_var("BACKUP_MINUTE", minute)
    update_env_var("BACKUP_DAY_WEEK", day_week)
    update_env_var("BACKUP_DAY_MONTH", day_month)

    # Validate Inputs (Hardening)
    try:
        # Ensure numeric values are integers within valid ranges
        if not (0 <= int(minute) <= 59) or not (0 <= int(hour) <= 23):
            raise ValueError("Invalid time format")
        if day_month != "*" and not (1 <= int(day_month) <= 31):
            raise ValueError("Invalid day of month")
        if day_week != "*" and not (0 <= int(day_week) <= 6):
            raise ValueError("Invalid day of week")
    except ValueError as e:
        return jsonify({"error": str(e)}), 400

    # Update Cron File
    # Cron format: min hour dom month dow
    cron_line = f"{minute} {hour} {day_month} * {day_week} root bash {SCRIPT_BACKUP} >> {LOG_FILES['backup']} 2>&1\n"
    try:
        # Ensure permissions are restricted
        with open(CRON_FILE, "w") as f:
            f.write("# Generated by HomeBrain Manager\n")
            f.write(cron_line)
        os.chmod(CRON_FILE, 0o644)
        return jsonify({"status": "success"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# --- Routes: Backup & Restore Execution ---
@app.route("/api/backup/now", methods=["POST"])
def trigger_backup():
    if current_task_status["status"] == "running":
        return jsonify({"error": "Task running"}), 409

    # 'full' = Database + NC Data + NC Config + HA Config
    # 'data_only' = NC Data + HA Config (No Database, No NC Config)
    strategy = request.json.get("strategy", "full")

    # We delegate strictly to the bash script to ensure locking and consistent logic
    cmd = f"bash {SCRIPT_BACKUP} --strategy {strategy} >> {LOG_FILES['backup']} 2>&1"
    
    label = "Full System Backup" if strategy == "full" else "Data-Only Backup"
    
    threading.Thread(
        target=run_background_task, args=(label, cmd, "backup")
    ).start()
    return jsonify({"status": "started"})


@app.route("/api/backups/list")
def list_backups():
    backups = []
    if os.path.exists(BACKUP_DIR):
        for f in os.listdir(BACKUP_DIR):
            if f.endswith(".tar.gz"):
                path = os.path.join(BACKUP_DIR, f)
                try:
                    size = os.path.getsize(path) / (1024 * 1024)
                    # Infer type from filename injected by backup.sh
                    btype = "Data Only" if "data_only" in f else "Full System"
                    backups.append({"name": f, "size": f"{size:.2f} MB", "type": btype})
                except:
                    pass
    backups.sort(key=lambda x: x["name"], reverse=True)
    return jsonify(backups)


@app.route("/api/restore", methods=["POST"])
def trigger_restore():
    if current_task_status["status"] == "running":
        return jsonify({"error": "Task running"}), 409

    filename = request.json.get("filename")
    if not filename or "/" in filename:
        return jsonify({"error": "Invalid filename"}), 400
        
    full_path = os.path.join(BACKUP_DIR, filename)

    # restore.sh handles auto-detection of content (HA vs NC vs DB)
    cmd = f"bash {SCRIPT_RESTORE} {full_path} --no-prompt >> {LOG_FILES['restore']} 2>&1"
    task_name = "System Restore"

    threading.Thread(
        target=run_background_task, args=(task_name, cmd, "restore")
    ).start()
    return jsonify({"status": "started"})


# --- Routes: Tunnel Management ---
@app.route("/api/tunnel", methods=["POST"])
def update_tunnel():
    if current_task_status["status"] == "running":
        return jsonify({"error": "Task running"}), 409

    data = request.json
    action = data.get("action")

    # Ensure we are in Pangolin mode: Clear CF tokens
    update_env_var("CF_TOKEN_NC", None)
    update_env_var("CF_TOKEN_HA", None)

    if action == "revert":
        factory = get_factory_config()
        update_env_var("PANGOLIN_ENDPOINT", factory.get("PANGOLIN_ENDPOINT", ""))
        update_env_var("NEWT_ID", factory.get("NEWT_ID", ""))
        update_env_var("NEWT_SECRET", factory.get("NEWT_SECRET", ""))
        
        # Revert Domain Logic
        main_dom = factory.get("PANGOLIN_DOMAIN", "")
        update_env_var("PANGOLIN_DOMAIN", main_dom)
        update_env_var("MANAGER_DOMAIN", main_dom)
        update_env_var("NEXTCLOUD_TRUSTED_DOMAINS", f"nc.{main_dom}" if main_dom else "")
        update_env_var("HA_TRUSTED_DOMAINS", f"ha.{main_dom}" if main_dom else "")

    else:
        update_env_var("PANGOLIN_ENDPOINT", data.get("endpoint"))
        update_env_var("NEWT_ID", data.get("id"))
        update_env_var("NEWT_SECRET", data.get("secret"))
        
        # Consolidate Domain Logic
        if data.get("main_domain"):
            main_dom = data.get("main_domain")
            update_env_var("PANGOLIN_DOMAIN", main_dom)
            update_env_var("MANAGER_DOMAIN", main_dom)
            update_env_var("NEXTCLOUD_TRUSTED_DOMAINS", f"nc.{main_dom}")
            update_env_var("HA_TRUSTED_DOMAINS", f"ha.{main_dom}")

    # Trigger deploy script to update stack logic
    subprocess.run(["chmod", "+x", SCRIPT_REDEPLOY])
    cmd = f"bash {SCRIPT_REDEPLOY} >> {LOG_FILES['setup']} 2>&1"
    threading.Thread(
        target=run_background_task, args=("Update Tunnel (Pangolin)", cmd, "setup")
    ).start()
    return jsonify({"status": "started"})


# --- Routes: Tunnel Management (Cloudflare) ---
@app.route("/api/tunnel/cloudflare", methods=["POST"])
def update_tunnel_cloudflare():
    if current_task_status["status"] == "running":
        return jsonify({"error": "Task running"}), 409

    domain = request.json.get("domain")
    service = request.json.get("service")  # 'nc' or 'ha'
    token = request.json.get("token")

    if not token or not service:
        return jsonify({"error": "Missing token or service definition"}), 400

    # Write Token to .env
    if service == "nc":
        update_env_var("NEXTCLOUD_TRUSTED_DOMAINS", domain)
        update_env_var("CF_TOKEN_NC", token)
    elif service == "ha":
        update_env_var("HA_TRUSTED_DOMAINS", domain)
        update_env_var("CF_TOKEN_HA", token)

    # NOTE: We do not explicitly unset PANGOLIN vars here because
    # deploy.sh prioritizes CF tokens if present.
    # This allows a cleaner "Revert" later.

    subprocess.run(["chmod", "+x", SCRIPT_REDEPLOY])
    cmd = f"bash {SCRIPT_REDEPLOY} >> {LOG_FILES['setup']} 2>&1"
    threading.Thread(
        target=run_background_task, args=("Update Tunnel (Cloudflare)", cmd, "setup")
    ).start()
    return jsonify({"status": "started"})


@app.route("/api/tunnel/revert", methods=["POST"])
def revert_tunnel_provider():
    if current_task_status["status"] == "running":
        return jsonify({"error": "Task running"}), 409

    # To revert to factory (Pangolin)
    # 1. Clear CF tokens
    update_env_var("CF_TOKEN_NC", None)
    update_env_var("CF_TOKEN_HA", None)

    # 2. Restore Factory Pangolin vars
    factory = get_factory_config()
    update_env_var("PANGOLIN_ENDPOINT", factory.get("PANGOLIN_ENDPOINT", ""))
    update_env_var("NEWT_ID", factory.get("NEWT_ID", ""))
    update_env_var("NEWT_SECRET", factory.get("NEWT_SECRET", ""))
    update_env_var("NEXTCLOUD_TRUSTED_DOMAINS", factory.get("NC_DOMAIN", ""))
    update_env_var("HA_TRUSTED_DOMAINS", factory.get("HA_DOMAIN", ""))

    subprocess.run(["chmod", "+x", SCRIPT_REDEPLOY])
    cmd = f"bash {SCRIPT_REDEPLOY} >> {LOG_FILES['setup']} 2>&1"
    threading.Thread(
        target=run_background_task, args=("Revert to Factory Settings", cmd, "setup")
    ).start()
    return jsonify({"status": "started"})


# --- Routes: Maintenance & Updates ---
@app.route("/api/maintenance/mode", methods=["POST"])
def set_maintenance():
    mode = request.json.get("mode")
    flag = "--on" if mode == "on" else "--off"
    try:
        subprocess.check_call(
            f"docker compose -f {COMPOSE_FILE} exec -u www-data nextcloud php occ maintenance:mode {flag}",
            shell=True,
        )
        return jsonify({"status": "success"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# --- Routes: Hardware / Zigbee ---
@app.route("/api/hardware/serial")
def list_serial_devices():
    try:
        # Find USB and ACM devices
        devices = []
        for dev in os.listdir("/dev"):
            if dev.startswith("ttyUSB") or dev.startswith("ttyACM"):
                devices.append(f"/dev/{dev}")
        return jsonify(devices)
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/manager/zigbee", methods=["GET", "POST"])
def manage_zigbee():
    """
    GET: Returns the currently configured Zigbee device from the override file.
    POST: Updates the override file and restarts Home Assistant in the background.
    """

    # --- GET: Persistence Check ---
    if request.method == "GET":
        current_device = "none"
        if os.path.exists(OVERRIDE_FILE):
            try:
                with open(OVERRIDE_FILE, "r") as f:
                    content = f.read()
                    # Look for common serial device patterns in the mapped volume
                    if "/dev/ttyUSB0" in content: current_device = "/dev/ttyUSB0"
                    elif "/dev/ttyACM0" in content: current_device = "/dev/ttyACM0"
                    elif "/dev/ttyAMA0" in content: current_device = "/dev/ttyAMA0"
            except Exception as e:
                logging.error(f"Failed to read override file: {e}")
        return jsonify({"current": current_device})

    # --- POST: Configuration Update ---
    data = request.json
    device = data.get("device")
    valid_devices = ["/dev/ttyUSB0", "/dev/ttyACM0", "/dev/ttyAMA0", "none"]

    if device not in valid_devices:
        return jsonify({"error": "Invalid device path"}), 400

    try:
        if device == "none":
            if os.path.exists(OVERRIDE_FILE):
                os.remove(OVERRIDE_FILE)
            message = "Zigbee device removed."
        else:
            # Generate the override YAML. 
            # This ensures HA gets the device even if the main compose doesn't have it.
            yaml_content = f"""
services:
  homeassistant:
    devices:
      - {device}:{device}
"""
            with open(OVERRIDE_FILE, "w") as f:
                f.write(yaml_content.strip())
            message = f"Zigbee device set to {device}."

        # Robust Restart Logic:
        # We must tell Docker to use both files if the override exists, 
        # otherwise it won't see the new mapping during the restart.
        def restart_ha():
            compose_cmd = ["docker", "compose", "-f", COMPOSE_FILE]
            if os.path.exists(OVERRIDE_FILE):
                compose_cmd.extend(["-f", OVERRIDE_FILE])
            
            # Use 'up -d' instead of 'restart' because 'up' recreates 
            # the container if the hardware mapping (config) changed.
            compose_cmd.extend(["up", "-d", "homeassistant"])
            
            logging.info(f"Executing: {' '.join(compose_cmd)}")
            subprocess.run(compose_cmd, check=False)

        # Fire and forget to keep the UI responsive
        threading.Thread(target=restart_ha, daemon=True).start()

        return jsonify({
            "status": "success",
            "message": f"{message} Home Assistant is restarting..."
        })

    except Exception as e:
        logging.error(f"Zigbee update error: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route("/api/upgrade", methods=["POST"])
def trigger_upgrade():
    if current_task_status["status"] == "running":
        return jsonify({"error": "Task running"}), 409

    # 1. Fetch Active Profiles (Critical for Tunnels)
    # We reuse the bash logic to ensure consistency with deploy.sh
    try:
        profiles = subprocess.check_output(
            f"bash -c 'source {shlex.quote(INSTALL_DIR)}/scripts/common.sh; load_env; get_tunnel_profiles'", 
            shell=True
        ).decode().strip()
    except Exception as e:
        logging.error(f"Failed to fetch profiles: {e}")
        # Fail safe: don't proceed if we can't determine the profile, 
        # otherwise we might start the stack without the tunnel.
        return jsonify({"error": "Could not determine system profile. Upgrade aborted."}), 500

    # 2. Construct Docker Arguments
    safe_env = shlex.quote(ENV_FILE)
    safe_compose = shlex.quote(COMPOSE_FILE)
    safe_log = shlex.quote(LOG_FILES["setup"])
    
    # Handle Override File
    compose_args = f"-f {safe_compose}"
    if os.path.exists(OVERRIDE_FILE):
        safe_override = shlex.quote(OVERRIDE_FILE)
        compose_args += f" -f {safe_override}"

    # 3. Build the Command Chain
    # Note: 'profiles' variable contains flags (e.g. --profile cloudflare), so it cannot be quoted as a single string.
    cmd = (
        f"echo '=== Starting System & Stack Upgrade ===' > {safe_log}; "
        
        # Step A: OS Updates
        f"echo '[1/4] Updating System Packages...' >> {safe_log}; "
        "export DEBIAN_FRONTEND=noninteractive; "
        f"apt-get update >> {safe_log} 2>&1; "
        f"apt-get upgrade -y >> {safe_log} 2>&1; "
        f"apt-get autoremove -y >> {safe_log} 2>&1; "

        # Step B: Docker Pull (Updates Images)
        f"echo '[2/4] Pulling Docker Images...' >> {safe_log}; "
        f"docker compose --env-file {safe_env} {compose_args} {profiles} pull >> {safe_log} 2>&1; "

        # Step C: Docker Up (Recreates Containers)
        f"echo '[3/4] Restarting Stack...' >> {safe_log}; "
        f"docker compose --env-file {safe_env} {compose_args} {profiles} up -d --remove-orphans >> {safe_log} 2>&1; "
        
        # Step D: Cleanup
        f"echo '[4/4] Cleaning up...' >> {safe_log}; "
        f"docker image prune -f >> {safe_log} 2>&1; "
        
        f"echo '=== Upgrade Complete ===' >> {safe_log}"
    )

    threading.Thread(
        target=run_background_task, args=("System Upgrade", cmd, "setup")
    ).start()
    return jsonify({"status": "started"})

@app.route("/api/manager/check_update", methods=["GET"])
def check_manager_update():
    channel = request.args.get("channel", "stable") # 'stable' or 'beta'
    local_ver = get_local_version()
    
    try:
        remote_ref = ""
        message = ""
        update_available = False

        if channel == "stable":
            # Check Latest Release
            resp = requests.get(f"{REPO_API_URL}/releases/latest", timeout=5)
            if resp.status_code == 200:
                data = resp.json()
                remote_ref = data.get("tag_name", "")
                # Compare tags (Simple string comparison, semantic versioning library is better but heavy)
                if remote_ref != local_ver.get("ref"):
                    update_available = True
                    message = f"New Release Available: {remote_ref}"
                else:
                    message = f"Up to date ({remote_ref})"
            else:
                 # Fallback if no releases exist yet
                 message = "No releases found."

        else: # Beta / Dev
            # Check Main Branch Commit
            resp = requests.get(f"{REPO_API_URL}/commits/main", timeout=5)
            if resp.status_code == 200:
                data = resp.json()
                remote_ref = data.get("sha", "")[:7] # Short SHA
                if remote_ref != local_ver.get("ref"):
                    update_available = True
                    message = f"New Beta Commit: {remote_ref}"
                else:
                    message = f"Beta up to date ({remote_ref})"
            else:
                message = "Failed to fetch beta info."

        return jsonify({
            "available": update_available,
            "message": message,
            "current_ref": local_ver.get("ref"),
            "target_ref": remote_ref,
            "channel": channel
        })

    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/manager/update", methods=["POST"])
def do_manager_update():
    if current_task_status["status"] == "running":
        return jsonify({"error": "Task running"}), 409

    data = request.json
    channel = data.get("channel", "stable")
    target_ref = data.get("target_ref", "main")

    # Ensure update script is executable
    if not os.path.exists(SCRIPT_UPDATE):
         # Fallback: Try to chmod if it exists, or error out
         # In a broken state, one might curl the script here first
         return jsonify({"error": "Update script missing. Re-install required."}), 500

    subprocess.run(["chmod", "+x", SCRIPT_UPDATE])

    cmd = (
        f"echo 'Starting Manager Update ({channel})...' > {LOG_FILES['update']}; "
        f"{SCRIPT_UPDATE} {channel} {target_ref} >> {LOG_FILES['update']} 2>&1"
    )

    # Fire and forget thread, as the service will restart
    threading.Thread(target=lambda: subprocess.run(cmd, shell=True)).start()
    
    return jsonify({
        "status": "started", 
        "message": f"Updating to {channel} {target_ref}. Interface will restart."
    })

# --- Routes: FTP Management ---

@app.route("/api/ftp/users", methods=["GET"])
def list_ftp_users():
    """Parses VSFTPD config to return list of FTP users and their mapped Nextcloud users."""
    users = []
    user_conf_dir = "/etc/vsftpd/user_conf"
    
    if os.path.exists(user_conf_dir):
        try:
            for ftp_user in os.listdir(user_conf_dir):
                conf_path = os.path.join(user_conf_dir, ftp_user)
                nc_user = "Unknown"
                if os.path.isfile(conf_path):
                    with open(conf_path, "r") as f:
                        # We look for the comment we injected: # NC_USER=admin
                        for line in f:
                            if line.startswith("# NC_USER="):
                                nc_user = line.split("=")[1].strip()
                                break
                    users.append({"ftp_user": ftp_user, "nc_user": nc_user})
        except Exception as e:
            return jsonify({"error": str(e)}), 500
            
    return jsonify(users)

@app.route("/api/ftp/setup", methods=["POST"])
def setup_ftp():
    if current_task_status["status"] == "running":
        return jsonify({"error": "Task running"}), 409

    data = request.json
    nc_user = data.get("nc_user")
    ftp_user = data.get("ftp_user")
    ftp_pass = data.get("ftp_pass")

    if not all([nc_user, ftp_user, ftp_pass]):
        return jsonify({"error": "Missing required fields"}), 400
        
    # Validation: FTP User should be alphanumeric
    if not ftp_user.isalnum():
        return jsonify({"error": "FTP Username must be alphanumeric"}), 400

    # Ensure utility script is executable
    subprocess.run(["chmod", "+x", SCRIPT_UTILITIES])

    # Pass password securely? 
    # For simplicity in this context, we pass as arg, but in high security 
    # we would write to temp file or pipe. Since this is local root, args are acceptable-ish
    # but strictly speaking visible in ps. 
    # HARDENING: Use shlex to prevent injection.
    cmd = f"bash {SCRIPT_UTILITIES} setup {shlex.quote(nc_user)} {shlex.quote(ftp_user)} {shlex.quote(ftp_pass)} >> {LOG_FILES['setup']} 2>&1"

    threading.Thread(
        target=run_background_task, args=("Setup FTP Server", cmd, "setup")
    ).start()
    return jsonify({"status": "started"})

@app.route("/api/ftp/delete", methods=["POST"])
def delete_ftp():
    if current_task_status["status"] == "running":
        return jsonify({"error": "Task running"}), 409

    ftp_user = request.json.get("ftp_user")
    if not ftp_user or not ftp_user.isalnum():
        return jsonify({"error": "Invalid FTP username"}), 400

    cmd = f"bash {SCRIPT_UTILITIES} delete {shlex.quote(ftp_user)} >> {LOG_FILES['setup']} 2>&1"

    threading.Thread(
        target=run_background_task, args=("Delete FTP User", cmd, "setup")
    ).start()
    return jsonify({"status": "started"})

if __name__ == "__main__":
    try:
        migration.run_migrations()
    except Exception as e:
        # Log to file so we can see it, but don't crash the web server
        logging.error(f"CRITICAL: Migration failed: {e}")
        
    app.run(host="0.0.0.0", port=80)
