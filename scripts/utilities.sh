#!/bin/bash
set -euo pipefail

# Load Common Library
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/common.sh"

# Global Config
VSFTPD_CONF="/etc/vsftpd.conf"
FTP_PASSWD_FILE="/etc/vsftpd/ftppasswd"
USER_CONFIG_DIR="/etc/vsftpd/user_conf"

# --- Helper: Install Dependencies ---
ensure_ftp_dependencies() {
    if ! command -v vsftpd >/dev/null 2>&1; then
        log_info "Installing VSFTPD and utilities..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq vsftpd libpam-pwdfile apache2-utils inotify-tools
    fi
}

# --- Helper: Configure VSFTPD ---
configure_vsftpd() {
    load_env
    
    # Backup original if not done
    if [ ! -f "${VSFTPD_CONF}.bak" ]; then
        cp "$VSFTPD_CONF" "${VSFTPD_CONF}.bak"
    fi

    # Fix www-data home for chroot compatibility (Idempotent)
    local www_home
    www_home=$(getent passwd www-data | cut -d: -f6)
    if [ "$www_home" != "$NEXTCLOUD_DATA_DIR" ]; then
        log_info "Updating www-data home directory to $NEXTCLOUD_DATA_DIR..."
        usermod -d "$NEXTCLOUD_DATA_DIR" www-data
    fi

    # Write Config (Hardened)
    cat > "$VSFTPD_CONF" <<EOF
listen=YES
listen_ipv6=NO
local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=YES
guest_enable=YES
guest_username=www-data
virtual_use_local_privs=YES
user_sub_token=\$USER
local_root=${NEXTCLOUD_DATA_DIR}/\$USER/files/uploads
user_config_dir=${USER_CONFIG_DIR}
pam_service_name=vsftpd.virtual
pasv_min_port=40000
pasv_max_port=50000
EOF

    # Configure PAM
    if ! grep -q "pam_pwdfile.so" /etc/pam.d/vsftpd.virtual 2>/dev/null; then
        cat > /etc/pam.d/vsftpd.virtual <<EOF
auth    required pam_pwdfile.so pwdfile ${FTP_PASSWD_FILE}
account required pam_permit.so
EOF
    fi

    mkdir -p "$USER_CONFIG_DIR"
}

# --- Action: Setup FTP User ---
setup_ftp_user() {
    local nc_user="$1"
    local ftp_user="$2"
    local ftp_pass="$3"

    load_env
    ensure_ftp_dependencies
    configure_vsftpd

    # 1. Verify Nextcloud User
    local nc_cid=$(get_nc_cid)
    if [[ -z "$nc_cid" ]]; then die "Nextcloud container is not running."; fi
    
    if ! docker exec -u www-data "$nc_cid" php occ user:info "$nc_user" >/dev/null 2>&1; then
        die "Nextcloud user '$nc_user' does not exist."
    fi

    # 2. Create Upload Directory
    local upload_dir="${NEXTCLOUD_DATA_DIR}/${nc_user}/files/uploads"
    if [ ! -d "$upload_dir" ]; then
        log_info "Creating upload directory: $upload_dir"
        mkdir -p "$upload_dir"
        chown -R www-data:www-data "$upload_dir"
    fi

    # 3. Add/Update Virtual FTP User
    # Use -B to verify bcrypt compatibility if needed, but md5 (-d) is standard for pam_pwdfile
    if [ ! -f "$FTP_PASSWD_FILE" ]; then
        htpasswd -b -c -d "$FTP_PASSWD_FILE" "$ftp_user" "$ftp_pass"
    else
        htpasswd -b -d "$FTP_PASSWD_FILE" "$ftp_user" "$ftp_pass"
    fi

    # 4. Map FTP User to NC User Directory
    # We store the NC user in a comment for the API to read back later
    echo "# NC_USER=${nc_user}" > "${USER_CONFIG_DIR}/${ftp_user}"
    echo "local_root=${NEXTCLOUD_DATA_DIR}/${nc_user}/files/uploads" >> "${USER_CONFIG_DIR}/${ftp_user}"

    # 5. Setup Watcher Service (inotify)
    local service_name="nextcloud-ftp-sync@${nc_user}"
    local watcher_script="/usr/local/bin/nextcloud-ftp-sync.sh"
    
    # Create robust watcher script
    cat > "$watcher_script" <<EOF
#!/bin/bash
NC_USER="\$1"
WATCH_DIR="${NEXTCLOUD_DATA_DIR}/\$NC_USER/files/uploads"
# Wait for Docker
until docker info >/dev/null 2>&1; do sleep 5; done

while true; do
  # Wait for file events
  inotifywait -e close_write,moved_to,create -r "\$WATCH_DIR"
  
  # Trigger Scan (debounce slightly)
  sleep 2
  NC_CID=\$(docker compose -f "${COMPOSE_FILE}" ps -q nextcloud 2>/dev/null)
  if [[ -n "\$NC_CID" ]]; then
      echo "Scanning files for \$NC_USER..."
      docker exec -u www-data "\$NC_CID" php occ files:scan --path="/\$NC_USER/files/uploads"
  fi
done
EOF
    chmod +x "$watcher_script"

    # Create/Enable Systemd Service template
    if [ ! -f /etc/systemd/system/nextcloud-ftp-sync@.service ]; then
        cat > /etc/systemd/system/nextcloud-ftp-sync@.service <<EOF
[Unit]
Description=Nextcloud FTP Sync Watcher for %i
After=docker.service

[Service]
ExecStart=$watcher_script %i
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi

    systemctl enable --now "$service_name"
    systemctl restart vsftpd
    
    log_info "FTP User '$ftp_user' mapped to Nextcloud user '$nc_user' successfully."
}

# --- Action: Delete FTP User ---
delete_ftp_user() {
    local ftp_user="$1"
    
    if [ -f "$FTP_PASSWD_FILE" ]; then
        htpasswd -D "$FTP_PASSWD_FILE" "$ftp_user"
    fi
    
    if [ -f "${USER_CONFIG_DIR}/${ftp_user}" ]; then
        rm "${USER_CONFIG_DIR}/${ftp_user}"
    fi
    
    # Note: We do NOT stop the sync service because multiple FTP users might map to the same NC user.
    # Service cleanup is left manual or handled by a deeper logic if needed.
    
    systemctl restart vsftpd
    log_info "FTP User '$ftp_user' deleted."
}

# --- Main Dispatch ---
case "${1:-}" in
    setup)
        setup_ftp_user "${2}" "${3}" "${4}"
        ;;
    delete)
        delete_ftp_user "${2}"
        ;;
    *)
        echo "Usage: $0 {setup <nc_user> <ftp_user> <ftp_pass> | delete <ftp_user>}"
        exit 1
        ;;
esac