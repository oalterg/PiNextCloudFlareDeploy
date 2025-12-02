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
UPDATE_URL = (
    "https://raw.githubusercontent.com/oalterg/pinextcloudflaredeploy/main/provision.sh"
)

LOG_FILES = {
    "setup": f"{LOG_DIR}/main_setup.log",
    "backup": f"{LOG_DIR}/backup.log",
    "restore": f"{LOG_DIR}/restore.log",
    "update": f"{LOG_DIR}/manager_update.log",
}

task_lock = threading.Lock()
current_task_status = {"status": "idle", "message": "", "log_type": "setup"}


# --- Helpers ---
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


# --- Route: Trigger Initial Setup ---
@app.route("/start_setup", methods=["POST"])
def start_setup():
    if is_setup_complete():
        return jsonify({"error": "Setup already complete"}), 400

    # Trigger raspi-cloud in headless mode
    # The --headless flag is handled in raspi-cloud to run the full stack deploy
    cmd = f"{RASPI_CLOUD_BIN} --headless >> {LOG_FILES['setup']} 2>&1"
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

    # Robustness: Get UUID and FSType to ensure it is mountable
    try:
        uuid = (
            subprocess.check_output(f"blkid -o value -s UUID {drive_path}", shell=True)
            .decode()
            .strip()
        )
        fstype = (
            subprocess.check_output(f"blkid -o value -s TYPE {drive_path}", shell=True)
            .decode()
            .strip()
        )

        if not uuid:
            return jsonify({"error": "No UUID found. Format drive first."}), 400
        if fstype not in ["ext4", "ext3", "xfs"]:
            return jsonify({"error": f"Unsupported filesystem ({fstype})"}), 400
    except:
        return jsonify({"error": "Could not read drive info"}), 500

    # Idempotence: Update fstab safely
    cmd = (
        f"umount {drive_path} || true; "
        f"mkdir -p {BACKUP_DIR}; "
        # Remove any existing entry for the backup dir to avoid conflicts
        f"sed -i '\|{BACKUP_DIR}|d' /etc/fstab; "
        # Add new entry
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
        return render_template("installing.html")

    factory = get_factory_config()
    env = get_env_config()

    # Determine Tunnel Provider Mode
    # If any CF token exists, we are in Cloudflare mode
    cf_mode = bool(env.get("CF_TOKEN_NC") or env.get("CF_TOKEN_HA"))

    # Check if Pangolin is custom (only relevant if not in CF mode)
    is_custom_pangolin = False
    if not cf_mode:
        is_custom_pangolin = env.get("PANGOLIN_ENDPOINT") != factory.get(
            "PANGOLIN_ENDPOINT"
        )

    return render_template(
        "dashboard.html",
        nc_domain=env.get("NEXTCLOUD_TRUSTED_DOMAINS"),
        ha_domain=env.get("HA_TRUSTED_DOMAINS"),
        creds={
            "user": env.get("NEXTCLOUD_ADMIN_USER"),
            "pass": env.get("NEXTCLOUD_ADMIN_PASSWORD"),
        },
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
        "homeassistant": "missing",
        "tunnel": "stopped",
    }
    try:
        # Docker Services Check
        # We need to check for either newt OR cloudflared-*
        out = subprocess.check_output(
            f"docker compose -f {COMPOSE_FILE} ps --format '{{{{.Service}}}}:{{{{.State}}}}:{{{{.Health}}}}'",
            shell=True,
        ).decode()

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
            # Load Avg (1 min)
            load1, _, _ = os.getloadavg()
            services["cpu_load"] = round(load1, 2)

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
            if dev["type"] != "disk":
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

    # Update Cron File
    # Cron format: min hour dom month dow
    cron_line = f"{minute} {hour} {day_month} * {day_week} root {RASPI_CLOUD_BIN} --backup >> {LOG_FILES['backup']} 2>&1\n"
    try:
        with open(CRON_FILE, "w") as f:
            f.write("# Generated by Appliance Manager\n")
            f.write(cron_line)
        return jsonify({"status": "success"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# --- Routes: Backup & Restore Execution ---
@app.route("/api/backup/now", methods=["POST"])
def trigger_backup():
    if current_task_status["status"] == "running":
        return jsonify({"error": "Task running"}), 409

    strategy = request.json.get("strategy", "full")

    if strategy == "data_only":
        data_dir = get_env_config().get("NEXTCLOUD_DATA_DIR", "/home/admin/nextcloud")
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

    threading.Thread(
        target=run_background_task, args=(task_name, cmd, "backup")
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
    full_path = os.path.join(BACKUP_DIR, filename)

    if "data_only" in filename:
        data_dir = get_env_config().get("NEXTCLOUD_DATA_DIR", "/home/admin/nextcloud")
        cmd = (
            f"echo 'Restoring Data Only...' >> {LOG_FILES['restore']}; "
            f"tar -xzf {full_path} -C {data_dir} >> {LOG_FILES['restore']} 2>&1; "
            f"docker compose -f {COMPOSE_FILE} exec -u www-data nextcloud php occ files:scan --all >> {LOG_FILES['restore']} 2>&1"
        )
        task_name = "Data Restore"
    else:
        cmd = f"{RASPI_CLOUD_BIN} --restore {full_path} --no-prompt >> {LOG_FILES['restore']} 2>&1"
        task_name = "Full Restore"

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
    else:
        update_env_var("PANGOLIN_ENDPOINT", data.get("endpoint"))
        update_env_var("NEWT_ID", data.get("id"))
        update_env_var("NEWT_SECRET", data.get("secret"))

    # Trigger raspi-cloud to update stack logic
    cmd = f"{RASPI_CLOUD_BIN} --update-tunnels >> {LOG_FILES['setup']} 2>&1"
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
    # raspi-cloud prioritize CF tokens if present.
    # This allows a cleaner "Revert" later.

    cmd = f"{RASPI_CLOUD_BIN} --update-tunnels >> {LOG_FILES['setup']} 2>&1"
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

    cmd = f"{RASPI_CLOUD_BIN} --update-tunnels >> {LOG_FILES['setup']} 2>&1"
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


@app.route("/api/upgrade", methods=["POST"])
def trigger_upgrade():
    if current_task_status["status"] == "running":
        return jsonify({"error": "Task running"}), 409

    # Safe System Upgrade (Standard Updates Only, no Dist-Upgrade)
    cmd = (
        "echo 'Starting System Update...' > " + LOG_FILES["setup"] + "; "
        "export DEBIAN_FRONTEND=noninteractive; "
        "apt-get update >> " + LOG_FILES["setup"] + " 2>&1; "
        "apt-get upgrade -y >> " + LOG_FILES["setup"] + " 2>&1; "
        "echo 'Updating Docker Containers...' >> " + LOG_FILES["setup"] + "; "
        f"cd {REPO_DIR} && docker compose pull >> " + LOG_FILES["setup"] + " 2>&1 && "
        "docker compose up -d >> " + LOG_FILES["setup"] + " 2>&1"
    )
    threading.Thread(
        target=run_background_task, args=("System Upgrade", cmd, "setup")
    ).start()
    return jsonify({"status": "started"})


@app.route("/api/manager/check_update", methods=["GET"])
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


@app.route("/api/manager/update", methods=["POST"])
def do_manager_update():
    if current_task_status["status"] == "running":
        return jsonify({"error": "Task running"}), 409

    if not os.path.exists(FACTORY_CONFIG):
        return (
            jsonify({"error": "Factory config missing, cannot re-provision safely"}),
            500,
        )

    # Retrieve existing factory config via Python to safely pass to the new script.
    # We avoid relying on shell 'source' which can fail to export variables to child processes.
    config = get_factory_config()

    # Prepare arguments using shlex.quote to prevent shell injection/corruption
    args = [
        config.get("NEWT_ID", ""),
        config.get("NEWT_SECRET", ""),
        config.get("NC_DOMAIN", ""),
        config.get("HA_DOMAIN", ""),
        config.get("PANGOLIN_ENDPOINT", ""),
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
    return jsonify(
        {
            "status": "started",
            "message": "Manager updating. Service will restart momentarily.",
        }
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
