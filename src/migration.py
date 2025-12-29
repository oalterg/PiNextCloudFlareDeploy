import os
import shutil
import logging

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
