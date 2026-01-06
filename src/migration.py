import os
import shutil
import logging
import subprocess

# Configuration Constants
INSTALL_DIR = "/opt/homebrain"
ENV_FILE = os.path.join(INSTALL_DIR, ".env")
FACTORY_CONFIG = "/boot/firmware/factory_config.txt"

def get_env_map():
    config = {}
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE, "r") as f:
            for line in f:
                if "=" in line and not line.strip().startswith("#"):
                    key, value = line.strip().split("=", 1)
                    config[key] = value.strip()
    return config

def update_env_file(updates):
    """Updates the .env file with a dictionary of key-value pairs."""
    if not updates:
        return

    # Read existing
    lines = []
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE, "r") as f:
            lines = f.readlines()

    for key, value in updates.items():
        found = False
        new_line = f"{key}={value}\n"
        for i, line in enumerate(lines):
            if line.startswith(f"{key}="):
                lines[i] = new_line
                found = True
                break
        if not found:
            if lines and not lines[-1].endswith("\n"):
                lines.append("\n")
            lines.append(new_line)

    with open(ENV_FILE, "w") as f:
        f.writelines(lines)
    
    # Secure the file
    os.chmod(ENV_FILE, 0o600)

def run_migrations():
    """Main entry point for migration logic."""
    logging.info("Checking for system migrations...")
    
    env = get_env_map()
    updates = {}
    migrated = False

    # --- Migration 1: Legacy Domain Structure (pre-Pangolin) ---
    if "PANGOLIN_DOMAIN" not in env:
        logging.info("Migration: Legacy configuration detected (Missing PANGOLIN_DOMAIN).")
        
        legacy_nc = env.get("NEXTCLOUD_TRUSTED_DOMAINS", "")
        
        # Try factory config if .env is empty
        if not legacy_nc and os.path.exists(FACTORY_CONFIG):
             with open(FACTORY_CONFIG) as f:
                 for line in f:
                     if "NC_DOMAIN=" in line:
                         legacy_nc = line.split("=")[1].strip()

        if legacy_nc:
            # Derive base domain (e.g. nc.example.com -> example.com)
            base_domain = legacy_nc.replace("nc.", "")
            logging.info(f"Migration: Derived PANGOLIN_DOMAIN={base_domain} from {legacy_nc}")
            
            updates["PANGOLIN_DOMAIN"] = base_domain
            updates["MANAGER_DOMAIN"] = base_domain
            
            # Persist to factory config for recovery
            with open(FACTORY_CONFIG, "a") as f:
                f.write(f"\nPANGOLIN_DOMAIN={base_domain}\n")
            
            migrated = True

    # --- Migration 2: Consolidate Password (Master Password) ---
    # If Manager Password is missing but Nextcloud exists, adopt it.
    if "MANAGER_PASSWORD" not in env and "NEXTCLOUD_ADMIN_PASSWORD" in env:
        logging.info("Migration: Consolidating credentials. Setting Manager Password to match Nextcloud.")
        nc_pass = env["NEXTCLOUD_ADMIN_PASSWORD"]
        updates["MANAGER_PASSWORD"] = nc_pass
        updates["MASTER_PASSWORD"] = nc_pass
        migrated = True

    if migrated and updates:
        update_env_file(updates)
        logging.info(f"Migration: Applied {len(updates)} updates to environment.")

    # --- Migration 3: Install Gunicorn if Missing ---
    try:
        import gunicorn
        logging.info("Migration: Gunicorn already installed.")
    except ImportError:
        logging.info("Migration: Installing Gunicorn...")
        try:
            subprocess.run(["pip3", "install", "gunicorn"], check=True, capture_output=True)
            logging.info("Migration: Gunicorn installed successfully.")
        except subprocess.CalledProcessError as e:
            logging.error(f"Migration: Failed to install Gunicorn: {e}. Manual installation required.")
            return  # Do not proceed with service migration if install fails

    # --- Migration 4: Switch Service to Gunicorn ---
    service_file = "/etc/systemd/system/homebrain-manager.service"
    if not os.path.exists(service_file):
        logging.info("Migration: Service file not found. Skipping Gunicorn service migration.")
        return

    with open(service_file, "r") as f:
        lines = f.readlines()

    # Idempotency: Skip if already using Gunicorn
    if any("gunicorn" in line for line in lines):
        logging.info("Migration: Service already configured for Gunicorn. Skipping.")
        return

    # Backup original
    backup_file = service_file + ".bak"
    if not os.path.exists(backup_file):
        shutil.copy(service_file, backup_file)
        logging.info(f"Migration: Backup created: {backup_file}")

    # Process lines for updates
    new_lines = []
    has_environment = any(line.startswith("Environment=") for line in lines)
    has_restart_sec = any(line.startswith("RestartSec=") for line in lines)

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("ExecStart="):
            # Replace any python3-based ExecStart
            new_lines.append("ExecStart=/usr/local/bin/gunicorn --workers 3 --bind 0.0.0.0:80 --timeout 30 app:app\n")
        elif stripped.startswith("WorkingDirectory="):
            # Set to fixed path, regardless of previous value
            new_lines.append("WorkingDirectory=/opt/homebrain/src\n")
        else:
            new_lines.append(line)

    # Insert Environment if missing (after [Service])
    if not has_environment:
        for i, line in enumerate(new_lines):
            if line.strip() == "[Service]":
                new_lines.insert(i + 1, 'Environment="PATH=/usr/local/bin:/usr/bin:/bin"\n')
                break

    # Insert RestartSec if missing (after Restart=always)
    if not has_restart_sec:
        for i, line in enumerate(new_lines):
            if line.strip().startswith("Restart=always"):
                new_lines.insert(i + 1, "RestartSec=10\n")
                break

    # Write updated service file
    with open(service_file, "w") as f:
        f.writelines(new_lines)
    logging.info("Migration: Service file updated for Gunicorn.")

    # Reload systemd and restart service
    try:
        subprocess.run(["systemctl", "daemon-reload"], check=True, capture_output=True)
        subprocess.run(["systemctl", "restart", "homebrain-manager"], check=True, capture_output=True)
        logging.info("Migration: Systemd reloaded and service restarted successfully.")
    except subprocess.CalledProcessError as e:
        logging.error(f"Migration: Failed to reload/restart service: {e}. Manual intervention required (run 'systemctl daemon-reload' and 'systemctl restart homebrain-manager').")
