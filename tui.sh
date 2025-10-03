#!/bin/bash
# tui.sh — A TUI for managing the Nextcloud environment

set -euo pipefail

# --- Configuration ---
REPO_DIR="/opt/raspi-nextcloud-setup"
LOG_DIR="/var/log/raspi-nextcloud"
MAIN_LOG_FILE="$LOG_DIR/main_setup.log"
BACKUP_LOG_FILE="$LOG_DIR/backup.log"
RESTORE_LOG_FILE="$LOG_DIR/restore.log"
LVM_LOG_FILE="$LOG_DIR/lvm_migration.log"
FLASH_LOG_FILE="$LOG_DIR/flash_to_drive.log"
ENV_FILE="$REPO_DIR/.env"
COMPOSE_FILE="$REPO_DIR/docker-compose.yml"
CRON_FILE="/etc/cron.d/nextcloud-backup"
HEALTH_LOG_FILE="$LOG_DIR/health_check.log"
HEIGHT=20
WIDTH=70
CHOICE_HEIGHT=8
BOOT_PARTITION="/boot/firmware"  # Standard for Pi 5 Bookworm

# Detect boot device
root_dev=$(findmnt -o SOURCE / | tail -1 | cut -d'[' -f1)
if [[ $root_dev == /dev/mmcblk* ]]; then
    is_sd_boot=true
else
    is_sd_boot=false
fi

# --- Ensure dependencies and scripts are ready (idempotent) ---
if ! command -v dialog >/dev/null 2>&1; then
    echo "Error: 'dialog' is required but not installed." >&2
    exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
    echo "Error: 'docker' is required but not installed." >&2
    exit 1
fi

mkdir -p "$LOG_DIR"
chmod +x "$REPO_DIR/setup.sh" "$REPO_DIR/backup.sh" "$REPO_DIR/restore.sh" 2>/dev/null || true

# --- Helper Functions ---
die() { dialog --title "Error" --msgbox "$1" 8 60; exit 1; }

get_nc_cid() {
    docker compose -f "$COMPOSE_FILE" ps -q nextcloud 2>/dev/null || true
}

is_stack_running() {
    [[ -n "$(get_nc_cid)" ]]
}

wait_for_completion() {
    local pid=$1
    local title=$2
    local text=$3
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
    done
    wait "$pid"
    return $?
}

reset_terminal() {
    sleep 0.5
    stty sane 2>/dev/null || true
}

# Auto-detect backup drive (reusable)
auto_detect_backup_drive() {
    local detected_dev backup_label
    detected_dev=$(lsblk -o NAME,TYPE,RM,SIZE,MOUNTPOINT | grep 'disk' | grep -v '^sda\|nvme0n1' | awk '$3=="1" && $5=="" {print "/dev/"$1; exit}')
    if [[ -n "$detected_dev" ]]; then
        backup_label=$(blkid -o value -s LABEL "$detected_dev" 2>/dev/null || echo "AutoLabel_$(date +%Y%m%d)")
        echo "$detected_dev|$backup_label"
    else
        echo "|LocalFallback"
    fi
}

# Update .env with new values (idempotent)
update_env() {
    local key="$1" value="$2"
    if grep -q "^$key=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^$key=.*|$key=$value|" "$ENV_FILE"
    else
        echo "$key=$value" >> "$ENV_FILE"
    fi
}

# Install/update cron job based on custom schedule
install_backup_cron() {
    local minute="$1" hour="$2" day_of_month="$3" month="$4" day_of_week="$5"
    local cron_expr="$minute $hour $day_of_month $month $day_of_week"

    local cron_content="# Run Nextcloud backup at $cron_expr\n$cron_expr root $REPO_DIR/backup.sh >> $BACKUP_LOG_FILE 2>&1\n"
    if [[ -f "$CRON_FILE" && $(cat "$CRON_FILE") == *"$cron_expr"* ]]; then
        echo "Cron job already up-to-date for schedule $cron_expr."
    else
        echo -e "$cron_content" > "$CRON_FILE"
        chmod 644 "$CRON_FILE"
        echo "Cron job updated for schedule $cron_expr."
    fi
}

# Configure backup drive (mount/format)
configure_backup_drive() {
    local backup_label="$1" mount_dir="$2" auto_format="$3"
    local detected_info auto_dev suggested_label

    # Auto-detect suggestion
    detected_info=$(auto_detect_backup_drive)
    auto_dev=$(echo "$detected_info" | cut -d'|' -f1)
    suggested_label=$(echo "$detected_info" | cut -d'|' -f2)

    if [[ "$auto_dev" != "" && "$suggested_label" != "LocalFallback" ]]; then
        dialog --msgbox "Detected external drive: $auto_dev\nSuggested label: $suggested_label\n(You can override below)" 10 60
    fi

    local values
    values=$(dialog --backtitle "Backup Drive Configuration" \
        --stdout \
        --title "Configure Backup Drive" \
        --form "Enter backup drive details:" \
        15 60 8 \
        "Mount Point:" 1 1 "$mount_dir" 1 20 40 0 \
        "Label:"       2 1 "${backup_label:-$suggested_label}" 2 20 40 0 \
        "Auto-Format? (Y/N):" 3 1 "${auto_format:-N}" 3 20 10 0)
    local retval=$?
    if [ $retval -ne 0 ] || [ -z "$values" ]; then
        return 1
    fi

    mapfile -t values_array <<< "$values"
    local new_mount="${values_array[0]}"
    local new_label="${values_array[1]}"
    local new_format="${values_array[2]}"

    # Update .env
    update_env "BACKUP_MOUNTDIR" "$new_mount"
    update_env "BACKUP_LABEL" "$new_label"
    update_env "AUTO_FORMAT_BACKUP" "$new_format"

    mkdir -p "$new_mount"

    # Format if requested and needed
    if [[ "$new_format" == "Y" || "$new_format" == "y" ]]; then
        dialog --title "WARNING" --yesno "Formatting will ERASE all data on the drive with label '$new_label'. Proceed?" 8 60
        if [ $? -eq 0 ]; then
            local dev
            dev=$(blkid -L "$new_label" 2>/dev/null || echo "$auto_dev")
            if [[ -n "$dev" ]]; then
                mkfs.ext4 -F -L "$new_label" "$dev" >> "$BACKUP_LOG_FILE" 2>&1
                echo "[INFO] Formatted drive $dev with label $new_label" >> "$BACKUP_LOG_FILE"
            else
                dialog --title "Error" --msgbox "Drive not found for formatting." 8 50
                return 1
            fi
        else
            return 0
        fi
    fi

    # Mount
    if ! mountpoint -q "$new_mount"; then
        if blkid -L "$new_label" >/dev/null 2>&1; then
            mount -L "$new_label" "$new_mount" || {
                dialog --title "Error" --msgbox "Failed to mount drive." 8 50
                return 1
            }
            # Add to fstab if not present
            local uuid
            uuid=$(blkid -o value -s UUID -L "$new_label")
            if ! grep -q "$uuid" /etc/fstab; then
                echo "UUID=$uuid $new_mount ext4 defaults,nofail 0 2" >> /etc/fstab
            fi
        else
            dialog --title "Error" --msgbox "Drive with label '$new_label' not found." 8 50
            return 1
        fi
    fi

    dialog --title "Success" --msgbox "Backup drive configured and mounted at $new_mount." 8 50
}

# System Health Check
system_health_check() {
    touch "$HEALTH_LOG_FILE"
    chmod 644 "$HEALTH_LOG_FILE"

    (
        echo "=== System Health Check Started at $(date) ==="

        # Docker status
        echo "[CHECK] Docker service:"
        if systemctl is-active --quiet docker; then
            echo "  ✅ Docker is running"
        else
            echo "  ❌ Docker is not running"
        fi

        # Stack status
        echo "[CHECK] Nextcloud stack:"
        if is_stack_running; then
            echo "  ✅ Stack is running"
            local nc_cid db_cid
            nc_cid=$(get_nc_cid)
            db_cid=$(docker compose -f "$COMPOSE_FILE" ps -q db 2>/dev/null)
            if [[ -n "$nc_cid" && -n "$db_cid" ]]; then
                local nc_health db_health
                nc_health=$(docker inspect --format="{{if .State.Health}}{{.State.Health.Status}}{{end}}" "$nc_cid" 2>/dev/null || echo "unknown")
                db_health=$(docker inspect --format="{{if .State.Health}}{{.State.Health.Status}}{{end}}" "$db_cid" 2>/dev/null || echo "unknown")
                echo "  Nextcloud health: $nc_health"
                echo "  DB health: $db_health"
            fi
        else
            echo "  ❌ Stack is not running"
        fi

        # Disk space
        echo "[CHECK] Disk usage:"
        df -h / | tail -1 | awk '{print "  Root: " $5 " used (" $4 " available)"}'
        source "$ENV_FILE" 2>/dev/null || true
        local backup_dir="${BACKUP_MOUNTDIR:-/mnt/backup}"
        if mountpoint -q "$backup_dir"; then
            df -h "$backup_dir" | tail -1 | awk '{print "  Backup: " $5 " used (" $4 " available)"}'
        else
            echo "  Backup dir not mounted"
        fi

        # Backup drive mount
        echo "[CHECK] Backup drive:"
        if mountpoint -q "$backup_dir"; then
            echo "  ✅ Mounted at $backup_dir"
        else
            echo "  ❌ Not mounted"
        fi

        # Cron job
        echo "[CHECK] Backup cron:"
        if [[ -f "$CRON_FILE" ]]; then
            echo "  ✅ Installed: $(head -1 "$CRON_FILE")"
        else
            echo "  ❌ Not installed"
        fi

        # Log errors (last 50 lines)
        echo "[CHECK] Recent errors in logs:"
        grep -i "error\|fail\|warn" "$MAIN_LOG_FILE" "$BACKUP_LOG_FILE" "$RESTORE_LOG_FILE" 2>/dev/null | tail -20 || echo "  No recent errors"

        # Nextcloud occ status (if running)
        if [[ -n "$nc_cid" ]]; then
            echo "[CHECK] Nextcloud status:"
            docker exec -u www-data "$nc_cid" php occ status 2>/dev/null || echo "  Could not query"
        fi

        echo "=== Health Check Completed at $(date) ==="
    ) >> "$HEALTH_LOG_FILE" 2>&1

    dialog --title "System Health Check" --textbox "$HEALTH_LOG_FILE" 25 80
}

trigger_backup() {
    source "$ENV_FILE" 2>/dev/null || true
    local backup_dir="${BACKUP_MOUNTDIR:-/mnt/backup}"
    if ! mountpoint -q "$backup_dir"; then
        dialog --title "Error" --msgbox "Backup directory not mounted." 8 50
        return 1
    fi

    (
        "$REPO_DIR/backup.sh"
    ) >> "$BACKUP_LOG_FILE" 2>&1 &  # Append for history
    local pid=$!

    dialog --title "Backup Log" --tailbox "$BACKUP_LOG_FILE" 25 80 &
    local tail_pid=$!

    wait_for_completion "$pid" "Backup in Progress" "Backing up data... (Check log for details)"
    local exit_code=$?
    
    kill "$tail_pid" 2>/dev/null || true
    reset_terminal
    
    if [ $exit_code -eq 0 ]; then
        dialog --title "Success" --msgbox "Backup completed successfully!" 8 40
    else
        dialog --title "Error" --msgbox "Backup failed. Check logs in $BACKUP_LOG_FILE" 8 60
    fi
}

trigger_restore() {
    source "$ENV_FILE" 2>/dev/null || true
    local backup_dir="${BACKUP_MOUNTDIR:-/mnt/backup}"
    # Use time-based sort for newest-first, limit to 20 for usability
    mapfile -t backups < <(ls -t "$backup_dir"/nextcloud_backup_*.tar.gz 2>/dev/null | xargs -n1 basename | head -20)

    if [ ${#backups[@]} -eq 0 ]; then
        dialog --title "Error" --msgbox "No backup files found in $backup_dir." 8 50
        return 1
    fi

    local options=()
    for i in "${!backups[@]}"; do
        options+=("$((i+1))" "${backups[$i]}")
    done
    
    local choice
    choice=$(dialog --stdout \
        --title "Select Backup to Restore" \
        --menu "Choose a backup file:" $HEIGHT $WIDTH $CHOICE_HEIGHT \
        "${options[@]}")
    local retval=$?
    if [ $retval -ne 0 ] || [ -z "$choice" ]; then
        return 0
    fi

    local selected_file="${backups[$((choice-1))]}"
    dialog --title "Confirm Restore" --yesno "This will OVERWRITE all current data. Are you absolutely sure you want to restore from:\n\n$selected_file?" 12 60
    if [ $? -eq 0 ]; then
        (
            "$REPO_DIR/restore.sh" "$backup_dir/$selected_file"
        ) >> "$RESTORE_LOG_FILE" 2>&1 &  # Append for history
        local pid=$!

        dialog --title "Restore Log" --tailbox "$RESTORE_LOG_FILE" 25 80 &
        local tail_pid=$!

        wait_for_completion "$pid" "Restore in Progress" "Restoring data from backup... (Check log for details)"
        local exit_code=$?
        
        kill "$tail_pid" 2>/dev/null || true
        reset_terminal
        
        if [ $exit_code -eq 0 ]; then
            dialog --title "Success" --msgbox "Restore completed successfully!" 8 40
        else
            dialog --title "Error" --msgbox "Restore failed. Check logs in $RESTORE_LOG_FILE" 8 60
        fi
    fi
}

toggle_maintenance_mode() {
    if ! is_stack_running; then
        dialog --title "Error" --msgbox "Nextcloud stack is not running." 8 50
        return 1
    fi

    local nc_cid
    nc_cid=$(get_nc_cid)
    if [[ -z "$nc_cid" ]]; then
        dialog --title "Error" --msgbox "Nextcloud container not found." 8 50
        return 1
    fi

    local current_status
    if ! current_status=$(docker exec -u www-data "$nc_cid" php occ maintenance:mode 2>&1); then
        dialog --title "Error" --msgbox "Failed to query maintenance mode: $current_status" 8 50
        return 1
    fi

    local status new_mode new_status
    if echo "$current_status" | grep -q "enabled"; then
        status="enabled"
        new_mode="--off"
        new_status="disabled"
    else
        status="disabled"
        new_mode="--on"
        new_status="enabled"
    fi

    dialog --title "Confirm" --yesno "Maintenance mode is currently $status. Do you want to turn it $new_status?" 10 60
    if [ $? -eq 0 ]; then
        if docker exec -u www-data "$nc_cid" php occ maintenance:mode "$new_mode" >/dev/null 2>&1; then
            dialog --title "Success" --msgbox "Maintenance mode is now $new_status." 8 40
        else
            dialog --title "Error" --msgbox "Failed to toggle maintenance mode." 8 50
        fi
    fi
    reset_terminal
}

run_files_scan() {
    if ! is_stack_running; then
        dialog --title "Error" --msgbox "Nextcloud stack is not running." 8 50
        return 1
    fi
    
    local user
    user=$(dialog --stdout \
        --inputbox "Enter username to scan (or '--all' for all users):" 8 60 "")
    local retval=$?
    if [ $retval -ne 0 ] || [ -z "$user" ]; then
        return 0
    fi

    dialog --title "Confirm Scan" --yesno "Scan files for user: '$user'?" 8 50
    if [ $? -eq 0 ]; then
        local nc_cid
        nc_cid=$(get_nc_cid)
        if [[ -z "$nc_cid" ]]; then
            dialog --title "Error" --msgbox "Nextcloud container not found." 8 50
            return 1
        fi
        (
            echo "=== File Scan Started at $(date) ===" 
            docker exec -u www-data "$nc_cid" php occ files:scan "$user"
            echo "=== File Scan Completed at $(date) ===" 
        ) >> "$MAIN_LOG_FILE" 2>&1 &  # Append to preserve history
        local pid=$!
        
        dialog --title "File Scan Log" --tailbox "$MAIN_LOG_FILE" 25 80 &
        local tail_pid=$!
        
        wait_for_completion "$pid" "Scan in Progress" "Scanning user files... (Check log for details)"
        kill "$tail_pid" 2>/dev/null || true
        reset_terminal
        
        dialog --title "Complete" --msgbox "File scan for '$user' finished. Check log for details." 8 60
    fi
}

get_ssd_drives() {
    lsblk -d -o NAME -n | grep -E '^(nvme[0-9]+n[0-9]+|sd[a-z])$' | sort
}

fix_cloudflare_repo() {
    echo "[INFO] Fixing Cloudflare repository configuration" >> "$1"
    sudo rm -f /etc/apt/sources.list.d/cloudflare*.list >> "$1" 2>&1
    sudo mkdir -p --mode=0755 /usr/share/keyrings >> "$1" 2>&1
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null 2>> "$1"
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared bookworm main' | sudo tee /etc/apt/sources.list.d/cloudflared.list >> "$1" 2>&1
}

# New: Flash OS to NVMe and Switch Boot (For Fresh SD to NVMe)
flash_to_nvme() {
    local root_dev
    root_dev=$(findmnt -o SOURCE / | tail -1 | cut -d'[' -f1)
    if [[ $root_dev != /dev/mmcblk* ]]; then
        die "This option is only available when booted from SD card."
    fi

    local drives
    drives=$(get_ssd_drives)
    mapfile -t drive_array <<< "$drives"
    if [ ${#drive_array[@]} -eq 0 ]; then
        die "No target SSD/NVMe drive detected."
    fi

    local target_name
    if [ ${#drive_array[@]} -eq 1 ]; then
        target_name=${drive_array[0]}
    else
        local options=()
        for i in "${!drive_array[@]}"; do
            local size
            size=$(lsblk -d -o SIZE -n /dev/"${drive_array[$i]}")
            options+=("$((i+1))" "${drive_array[$i]} ($size)")
        done
        local choice
        choice=$(dialog --stdout --title "Select Target Drive" --menu "Choose the drive to flash to:" 15 50 5 "${options[@]}")
        if [ $? -ne 0 ]; then return 0; fi
        target_name=${drive_array[$((choice-1))]}
    fi

    local part_suffix
    if [[ $target_name =~ ^nvme ]]; then
        part_suffix="p"
    else
        part_suffix=""
    fi
    local target_root_part="/dev/${target_name}${part_suffix}2"

    dialog --title "Warning" --yesno "This will clone the current OS from SD to /dev/$target_name, set boot priority, and reboot. The drive will be overwritten. Proceed?" 10 60
    if [ $? -ne 0 ]; then return 0; fi

    (
        echo "=== Flash to $target_name Started at $(date) ===" >> "$FLASH_LOG_FILE"

        fix_cloudflare_repo "$FLASH_LOG_FILE"
        apt update >> "$FLASH_LOG_FILE" 2>&1 || die "apt update failed."
        apt install -y git rsync >> "$FLASH_LOG_FILE" 2>&1 || die "Failed to install dependencies."
        git clone https://github.com/geerlingguy/rpi-clone.git /tmp/rpi-clone >> "$FLASH_LOG_FILE" 2>&1 || die "Failed to clone rpi-clone."
        cd /tmp/rpi-clone
        sudo cp rpi-clone rpi-clone-setup /usr/local/bin >> "$FLASH_LOG_FILE" 2>&1 || die "Failed to copy rpi-clone scripts."
        sudo chmod +x /usr/local/bin/rpi-clone /usr/local/bin/rpi-clone-setup >> "$FLASH_LOG_FILE" 2>&1 || die "Failed to make rpi-clone executable."
        rpi-clone "$target_name" -f -U -v >> "$FLASH_LOG_FILE" 2>&1 || die "Clone failed."
        
        # Add auto-start TUI on first boot
        mkdir -p /mnt/target
        mount "$target_root_part" /mnt/target >> "$FLASH_LOG_FILE" 2>&1 || die "Failed to mount new root."
        echo "if [ -f /first_boot_tui ]; then sudo $REPO_DIR/tui.sh; rm /first_boot_tui; fi" >> /mnt/target/etc/rc.local
        touch /mnt/target/first_boot_tui
        umount /mnt/target

        # Set boot order
        local boot_code
        if [[ $target_name =~ ^nvme ]]; then boot_code=B3; else boot_code=B2; fi
        raspi-config nonint do_boot_order "$boot_code" >> "$FLASH_LOG_FILE" 2>&1 || die "Failed to set boot order."

        echo "=== Flash to $target_name Completed at $(date) ===" >> "$FLASH_LOG_FILE"
    ) & 
    local pid=$!

    dialog --title "Flash Log" --tailbox "$FLASH_LOG_FILE" 25 80 &
    local tail_pid=$!

    wait_for_completion "$pid" "Flash to Drive in Progress" "Cloning and configuring... (Check log)"
    kill "$tail_pid" 2>/dev/null || true
    reset_terminal

    dialog --title "Complete" --yesno "Flash done. Reboot to $target_name now? (Remove SD card after shutdown)" 8 60
    if [ $? -eq 0 ]; then sudo reboot; fi

    dialog --title "Flash Log" --textbox "$FLASH_LOG_FILE" 25 80
}

# New: LVM Storage Extension Function (Phase-Aware, Automated)
lvm_storage_extension() {
    local drives
    drives=$(get_ssd_drives)
    mapfile -t drive_array <<< "$drives"
    if [ ${#drive_array[@]} -ne 2 ]; then
        die "Exactly two SSD/NVMe drives required for LVM extension."
    fi
    local primary=${drive_array[0]}
    local secondary=${drive_array[1]}
    local primary_suffix
    if [[ $primary =~ ^nvme ]]; then primary_suffix="p"; else primary_suffix=""; fi
    local secondary_suffix
    if [[ $secondary =~ ^nvme ]]; then secondary_suffix="p"; else secondary_suffix=""; fi

    local root_dev
    root_dev=$(findmnt -o SOURCE / | tail -1 | cut -d'[' -f1)  # e.g., /dev/nvme0n1p2, /dev/mmcblk0p2, /dev/mapper/rpi-vg-root-lv

    local original_root_partuuid
    original_root_partuuid=$(blkid -o value -s PARTUUID "/dev/${primary}${primary_suffix}2" 2>/dev/null)
    [[ -z "$original_root_partuuid" ]] && die "Could not determine PARTUUID of /dev/${primary}${primary_suffix}2. Cannot proceed."
 
    dialog --title "Warning" --yesno "This extends storage with LVM across dual drives (~1.8TB root). Requires SD card with Raspberry Pi OS Bookworm Lite. Backup data first. Proceed?" 12 60
    if [ $? -ne 0 ]; then return 0; fi

    (
        echo "=== LVM Migration Started at $(date) on root: $root_dev ===" >> "$LVM_LOG_FILE"

        if [[ $root_dev == /dev/"${primary}${primary_suffix}"* ]]; then
            # Phase 1: Preparation on original drive
            echo "[Phase 1] Preparing on original drive..." >> "$LVM_LOG_FILE"
            fix_cloudflare_repo "$LVM_LOG_FILE"
            apt update >> "$LVM_LOG_FILE" 2>&1 || die "apt update failed."
            apt install -y lvm2 initramfs-tools rsync parted >> "$LVM_LOG_FILE" 2>&1 || die "Failed to install dependencies."
            sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf
            cat <<EOF >> /etc/initramfs-tools/modules
nvme_core
nvme
dm-mod
dm-crypt
dm-snapshot
dm-thin-pool
dm-mirror
dm-log
dm-cache
dm-raid
EOF
            sort -u /etc/initramfs-tools/modules -o /etc/initramfs-tools/modules
            mkdir -p /etc/initramfs-tools/scripts/local-top
            cat <<EOF > /etc/initramfs-tools/scripts/local-top/force_lvm
#!/bin/sh
PREREQ=""
prereqs() { echo "\$PREREQ"; }
case "\$1" in prereqs) prereqs; exit 0;; esac
. /scripts/functions
modprobe -q nvme_core >/dev/null 2>&1
modprobe -q nvme >/dev/null 2>&1
modprobe -q dm-mod >/dev/null 2>&1
log_begin_msg "Waiting for secondary drive (up to 30s)"
for i in \$(seq 1 30); do
    if [ -b /dev/$secondary ]; then
        log_success_msg "Secondary drive found after \$i seconds"
        break
    fi
    sleep 1
done
lvm pvscan --cache
lvm vgscan --mknodes
lvm vgchange -ay rpi-vg || true
EOF
            chmod +x /etc/initramfs-tools/scripts/local-top/force_lvm
            update-initramfs -u -k $(uname -r) >> "$LVM_LOG_FILE" 2>&1 || die "Failed to update initramfs."
            cp /boot/initrd.img-$(uname -r) $BOOT_PARTITION/ || die "Failed to copy initrd."
            if ! grep -q "initramfs initrd.img-$(uname -r) followkernel" $BOOT_PARTITION/config.txt; then
                echo "[all]" >> $BOOT_PARTITION/config.txt
                echo "initramfs initrd.img-$(uname -r) followkernel" >> $BOOT_PARTITION/config.txt
            fi
            echo "[Phase 1 Complete] System prepared." >> "$LVM_LOG_FILE"

        elif [[ $root_dev == /dev/mmcblk* ]]; then
            # Phase 2: Migration on SD
            echo "[Phase 2] Migrating on SD..." >> "$LVM_LOG_FILE"
            fix_cloudflare_repo "$LVM_LOG_FILE"
            apt update >> "$LVM_LOG_FILE" 2>&1 || die "apt update failed."
            apt install -y lvm2 initramfs-tools rsync parted >> "$LVM_LOG_FILE" 2>&1 || die "Failed to install dependencies."
            vgremove -f rpi-vg 2>/dev/null || true
            pvremove -f /dev/$secondary 2>/dev/null || true
            wipefs -a /dev/$secondary 2>/dev/null || true
            parted /dev/$secondary mklabel gpt 2>/dev/null || true
            pvcreate -f /dev/$secondary >> "$LVM_LOG_FILE" 2>&1 || die "Failed to create PV."
            vgcreate rpi-vg /dev/$secondary >> "$LVM_LOG_FILE" 2>&1 || die "Failed to create VG."
            lvcreate -n root-lv -l 100%FREE rpi-vg >> "$LVM_LOG_FILE" 2>&1 || die "Failed to create LV."
            mkfs.ext4 -L root /dev/rpi-vg/root-lv >> "$LVM_LOG_FILE" 2>&1 || die "Failed to format LV."
            e2fsck -f -y /dev/rpi-vg/root-lv >> "$LVM_LOG_FILE" 2>&1 || true
            mkdir -p /mnt/old /mnt/new
            mount /dev/"${primary}${primary_suffix}2" /mnt/old >> "$LVM_LOG_FILE" 2>&1 || die "Failed to mount old root."
            mount /dev/rpi-vg/root-lv /mnt/new >> "$LVM_LOG_FILE" 2>&1 || die "Failed to mount new root."
            rsync -aAXv --delete /mnt/old/ /mnt/new/ >> "$LVM_LOG_FILE" 2>&1 || die "Rsync failed."
            mount /dev/"${primary}${primary_suffix}1" /mnt/new$BOOT_PARTITION >> "$LVM_LOG_FILE" 2>&1 || die "Failed to mount boot."
            sed -i "s|PARTUUID=$original_root_partuuid|/dev/mapper/rpi-vg-root-lv|" /mnt/new/etc/fstab || die "fstab update failed."
            sed -i 's|root=PARTUUID=[^ ]*|root=/dev/mapper/rpi-vg-root-lv rootfstype=ext4 rootdelay=30|' /mnt/new$BOOT_PARTITION/cmdline.txt || die "cmdline update failed."
            cp -r /etc/initramfs-tools/scripts/local-top/force_lvm /mnt/new/etc/initramfs-tools/scripts/local-top/ 2>/dev/null || true
            chmod +x /mnt/new/etc/initramfs-tools/scripts/local-top/force_lvm
            chroot /mnt/new update-initramfs -u -k $(uname -r) >> "$LVM_LOG_FILE" 2>&1 || die "Initramfs update on new root failed."
            cp /mnt/new/boot/initrd.img-$(uname -r) /mnt/new$BOOT_PARTITION/ || die "Initrd copy failed."
            umount /mnt/new$BOOT_PARTITION
            umount /mnt/new
            umount /mnt/old
            echo "[Phase 2 Complete] Set boot to primary drive via raspi-config, remove SD, reboot." >> "$LVM_LOG_FILE"

        elif [[ $root_dev == /dev/mapper/rpi-vg-root-lv ]]; then
            # Phase 3: Finalization on new LVM
            echo "[Phase 3] Finalizing on new LVM..." >> "$LVM_LOG_FILE"
            fix_cloudflare_repo "$LVM_LOG_FILE"
            apt update >> "$LVM_LOG_FILE" 2>&1 || die "apt update failed."
            apt install -y lvm2 >> "$LVM_LOG_FILE" 2>&1 || die "Failed to install lvm2."
            wipefs -a /dev/"${primary}${primary_suffix}2" >> "$LVM_LOG_FILE" 2>&1 || die "Wipefs failed."
            pvcreate -f /dev/"${primary}${primary_suffix}2" >> "$LVM_LOG_FILE" 2>&1 || die "PV create failed."
            vgextend rpi-vg /dev/"${primary}${primary_suffix}2" >> "$LVM_LOG_FILE" 2>&1 || die "VG extend failed."
            lvextend -l +100%FREE /dev/rpi-vg/root-lv >> "$LVM_LOG_FILE" 2>&1 || die "LV extend failed."
            resize2fs /dev/rpi-vg/root-lv >> "$LVM_LOG_FILE" 2>&1 || die "Resize failed."
            e2fsck -f -y /dev/rpi-vg/root-lv >> "$LVM_LOG_FILE" 2>&1 || true
            echo "[Phase 3 Complete] Storage extended." >> "$LVM_LOG_FILE"

        else
            die "Unknown root device: $root_dev. Aborting."
        fi

        echo "=== LVM Migration Completed at $(date) ===" >> "$LVM_LOG_FILE"
    ) & 
    local pid=$!

    dialog --title "LVM Log" --tailbox "$LVM_LOG_FILE" 25 80 &
    local tail_pid=$!

    wait_for_completion "$pid" "LVM Extension in Progress" "Processing phase... (Check log)"
    kill "$tail_pid" 2>/dev/null || true
    reset_terminal

    # Phase-specific prompts
    if [[ $root_dev == /dev/"${primary}${primary_suffix}"* ]]; then
        dialog --title "SD Card Prompt" --msgbox "Insert SD card with Raspberry Pi OS Bookworm Lite now. Then, boot to SD (raspi-config > Advanced > Boot Order > SD Card Boot). On SD, run:\ncurl -O https://github.com/oalterg/pinextcloudflaredeploy/raw/main/install.txt && sudo bash install.txt\nto install TUI repo. Then run sudo $REPO_DIR/tui.sh > Maintenance > Storage Extension for Phase 2." 15 70
    elif [[ $root_dev == /dev/mmcblk* ]]; then
        local boot_type
        if [[ $primary =~ ^nvme ]]; then boot_type="NVMe/PCIe Boot (B3)"; else boot_type="USB Boot (B2)"; fi
        dialog --title "Next Steps" --msgbox "Phase 2 done. Run raspi-config > Advanced > Boot Order > $boot_type, remove SD, reboot. If shell drops, manually activate: modprobe nvme_core nvme dm-mod; lvm pvscan --cache; vgscan --mknodes; vgchange -ay rpi-vg; exit." 12 60
    elif [[ $root_dev == /dev/mapper/rpi-vg-root-lv ]]; then
        dialog --title "Complete" --yesno "Phase 3 done. Reboot to confirm?" 8 50
        if [ $? -eq 0 ]; then sudo reboot; fi
    fi

    dialog --title "LVM Extension Log" --textbox "$LVM_LOG_FILE" 25 80
}

main_menu() {
    while true; do
        if $is_sd_boot; then
            local choice
            choice=$(dialog --backtitle "Nextcloud Pi Manager (SD Boot)" \
                --stdout \
                --title "Main Menu" \
                --cancel-label "Exit" \
                --menu "Select an option:" \
                $HEIGHT $WIDTH $CHOICE_HEIGHT \
                1 "Flash OS to Drive (NVMe/USB SSD)" \
                2 "Expand Filesystem with LVM")
            local retval=$?
            if [ $retval -ne 0 ]; then
                clear
                echo "Exiting."
                exit 0
            fi

            case "$choice" in
                1) flash_to_nvme ;;
                2) lvm_storage_extension ;;
            esac
        else
            local choice
            choice=$(dialog --backtitle "Nextcloud Pi Manager" \
                --stdout \
                --title "Main Menu" \
                --cancel-label "Exit" \
                --menu "Select an option:" \
                $HEIGHT $WIDTH $CHOICE_HEIGHT \
                1 "Initial System Setup" \
                2 "Backup/Restore" \
                3 "Maintenance" \
                4 "View Logs" \
                5 "System Health Check")
            local retval=$?
            if [ $retval -ne 0 ]; then
                clear
                echo "Exiting."
                exit 0
            fi

            case "$choice" in
                1) run_initial_setup ;;
                2) backup_restore_menu ;;
                3) maintenance_menu ;;
                4) logs_menu ;;
                5) system_health_check ;;
            esac
        fi
        reset_terminal  # Ensure clean state after actions
    done
}

backup_restore_menu() {
    while true; do
        local choice
        choice=$(dialog --stdout \
            --title "Backup/Restore Menu" \
            --menu "Select an action (or 0 to return):" $HEIGHT $WIDTH $CHOICE_HEIGHT \
            0 "Back to Main Menu" \
            1 "Configure Backup Settings" \
            2 "Trigger Manual Backup" \
            3 "Restore From Backup")
        local retval=$?
        if [ $retval -ne 0 ] || [ "$choice" = "0" ]; then
            return 0  # Explicit back or cancel -> return to main
        fi

        case "$choice" in
            1) configure_backup_settings ;;
            2) trigger_backup ;;
            3) trigger_restore ;;
        esac
        reset_terminal  # Clean after actions
    done
}

maintenance_menu() {
    while true; do
        local choice
        choice=$(dialog --stdout \
            --title "Maintenance Menu" \
            --menu "Select an action (or 0 to return):" $HEIGHT $WIDTH $CHOICE_HEIGHT \
            0 "Back to Main Menu" \
            1 "Toggle Maintenance Mode" \
            2 "Scan User Files (files:scan)" \
            3 "Expand Filesystem with LVM")
        local retval=$?
        if [ $retval -ne 0 ] || [ "$choice" = "0" ]; then
            return 0  # Explicit back or cancel -> return to main
        fi

        case "$choice" in
            1) toggle_maintenance_mode ;;
            2) run_files_scan ;;
            3) lvm_storage_extension ;;
        esac
        reset_terminal  # Clean after actions
    done
}

logs_menu() {
    while true; do
        local choice
        choice=$(dialog --stdout \
            --title "View Logs" \
            --menu "Select a log to view (or 0 to return):" $HEIGHT $WIDTH $CHOICE_HEIGHT \
            0 "Back to Main Menu" \
            1 "Main Setup Log" \
            2 "Backup Log" \
            3 "Restore Log" \
            4 "Docker Compose Logs" \
            5 "Health Check Log" \
            6 "LVM Migration Log" \
            7 "Flash to Drive Log")
        local retval=$?
        if [ $retval -ne 0 ] || [ "$choice" = "0" ]; then
            return 0  # Explicit back or cancel -> return to main
        fi
        
        case "$choice" in
            1) dialog --title "Setup Log" --tailbox "$MAIN_LOG_FILE" 25 80 ;;
            2) dialog --title "Backup Log" --tailbox "$BACKUP_LOG_FILE" 25 80 ;;
            3) dialog --title "Restore Log" --tailbox "$RESTORE_LOG_FILE" 25 80 ;;
            4) 
                local temp_log
                temp_log=$(mktemp /tmp/dockerlogs.XXXXXX)
                if docker compose -f "$COMPOSE_FILE" logs --tail=100 > "$temp_log" 2>&1; then
                    dialog --title "Docker Logs" --tailbox "$temp_log" 25 80
                else
                    dialog --title "Error" --msgbox "Failed to fetch Docker logs." 8 50
                fi
                rm -f "$temp_log"
                ;;
            5) dialog --title "Health Check Log" --tailbox "$HEALTH_LOG_FILE" 25 80 ;;
            6) dialog --title "LVM Log" --tailbox "$LVM_LOG_FILE" 25 80 ;;
            7) dialog --title "Flash Log" --tailbox "$FLASH_LOG_FILE" 25 80 ;;
        esac
        reset_terminal  # Clean after viewing
    done
}

configure_backup_settings() {
    source "$ENV_FILE" 2>/dev/null || true
    local current_mount="${BACKUP_MOUNTDIR:-/mnt/backup}"
    local current_label="${BACKUP_LABEL:-BackupDrive}"
    local current_format="${AUTO_FORMAT_BACKUP:-N}"
    local current_retention="${BACKUP_RETENTION:-8}"
    local current_minute="0" current_hour="3" current_dom="*" current_month="*" current_dow="0"  # Default weekly Sunday 03:00

    # Parse current cron if exists
    if [[ -f "$CRON_FILE" ]]; then
        local cron_line=$(grep -v '^#' "$CRON_FILE" | head -1)
        current_minute=$(echo "$cron_line" | awk '{print $1}')
        current_hour=$(echo "$cron_line" | awk '{print $2}')
        current_dom=$(echo "$cron_line" | awk '{print $3}')
        current_month=$(echo "$cron_line" | awk '{print $4}')
        current_dow=$(echo "$cron_line" | awk '{print $5}')
    fi

    local values
    values=$(dialog --backtitle "Backup Configuration" \
        --stdout \
        --title "Configure Backup Settings" \
        --form "Enter backup settings:" \
        18 60 10 \
        "Mount Point:" 1 1 "$current_mount" 1 20 40 0 \
        "Label:" 2 1 "$current_label" 2 20 40 0 \
        "Auto-Format? (Y/N):" 3 1 "$current_format" 3 20 10 0 \
        "Retention (days):" 4 1 "$current_retention" 4 20 10 0 \
        "Cron Minute (0-59):" 5 1 "$current_minute" 5 20 10 0 \
        "Cron Hour (0-23):" 6 1 "$current_hour" 6 20 10 0 \
        "Cron Day of Month (1-31):" 7 1 "$current_dom" 7 20 10 0 \
        "Cron Month (1-12):" 8 1 "$current_month" 8 20 10 0 \
        "Cron Day of Week (0-6):" 9 1 "$current_dow" 9 20 10 0)
    local retval=$?
    if [ $retval -ne 0 ] || [ -z "$values" ]; then
        return 0
    fi

    mapfile -t values_array <<< "$values"
    local new_mount="${values_array[0]}"
    local new_label="${values_array[1]}"
    local new_format="${values_array[2]}"
    local new_retention="${values_array[3]}"
    local new_minute="${values_array[4]}"
    local new_hour="${values_array[5]}"
    local new_dom="${values_array[6]}"
    local new_month="${values_array[7]}"
    local new_dow="${values_array[8]}"

    update_env "BACKUP_MOUNTDIR" "$new_mount"
    update_env "BACKUP_LABEL" "$new_label"
    update_env "AUTO_FORMAT_BACKUP" "$new_format"
    update_env "BACKUP_RETENTION" "$new_retention"

    configure_backup_drive "$new_label" "$new_mount" "$new_format"
    install_backup_cron "$new_minute" "$new_hour" "$new_dom" "$new_month" "$new_dow"
}

run_initial_setup() {
    # Check if stack is already running (idempotent: warn on re-run)
    if is_stack_running; then
        dialog --title "Warning" --yesno "Stack is already running. Re-run setup? (May reset config)" 8 50
        [[ $? -ne 0 ]] && return
    fi

    # Auto-scan backup drive
    local backup_label detected_dev
    detected_dev=$(lsblk -o NAME,TYPE,RM,SIZE,MOUNTPOINT | grep 'disk' | grep -v '^sda\|nvme0n1' | awk '$3=="1" && $5=="" {print "/dev/"$1; exit}')
    if [[ -n "$detected_dev" ]]; then
        backup_label=$(blkid -o value -s LABEL "$detected_dev" 2>/dev/null || echo "AutoLabel_$(date +%Y%m%d)")
        dialog --msgbox "Detected external drive: $detected_dev\nSuggested label: $backup_label\nFormat if needed?" 8 60
        export AUTO_FORMAT_BACKUP=true  # Enable if confirmed
    else
        backup_label="LocalFallback"
        export AUTO_FORMAT_BACKUP=false
    fi

    local values
    values=$(dialog --backtitle "Nextcloud Initial Setup" \
        --stdout \
        --title "Configuration" \
        --form "Enter your configuration details below." \
        25 60 16 \
        "Admin Password:"   1 1 ""            1 25 40 0 \
        "DB Root Password:" 2 1 ""            2 25 40 0 \
        "DB User Password:" 3 1 ""            3 25 40 0 \
        "Base Domain:"      4 1 "example.com" 4 25 40 0 \
        "Subdomain:"        5 1 "nextcloud"   5 25 40 0 \
        "Backup Label:"     6 1 "$backup_label" 6 25 40 0)
    local retval=$?
    if [ $retval -ne 0 ] || [ -z "$values" ]; then
        echo "[INFO] User canceled or dialog failed at $(date)" >> "$MAIN_LOG_FILE"
        return 1
    fi

    mapfile -t values_array <<< "$values"
    if [ "${#values_array[@]}" -lt 5 ]; then
        dialog --title "Input Error" --msgbox "All fields are required. Please try again." 8 50
        return 1
    fi

    local ADMIN_PASS="${values_array[0]}"
    local DB_ROOT_PASS="${values_array[1]}"
    local DB_USER_PASS="${values_array[2]}"
    local BASE_DOMAIN="${values_array[3]}"
    local SUBDOMAIN="${values_array[4]}"
    local BACKUP_LABEL="${values_array[5]}"  # Index 5 for new field
    export BACKUP_LABEL="${BACKUP_LABEL:-$backup_label}"  # Fallback to auto
    export AUTO_FORMAT_BACKUP=true  # Or from confirmation

    # Safeguard empty vars
    if [[ -z "$ADMIN_PASS" || -z "$DB_ROOT_PASS" || -z "$DB_USER_PASS" || -z "$BASE_DOMAIN" ]]; then
        dialog --title "Input Error" --msgbox "One or more fields are empty. Please try again." 8 50
        return 1
    fi

    # Ensure log file exists and is writable
    touch "$MAIN_LOG_FILE"
    chmod 644 "$MAIN_LOG_FILE"

    (
        set -x
        echo "--- TUI: Subshell for setup started at $(date) ---"
        export NEXTCLOUD_ADMIN_PASSWORD="$ADMIN_PASS"
        export MYSQL_ROOT_PASSWORD="$DB_ROOT_PASS"
        export MYSQL_PASSWORD="$DB_USER_PASS"
        export BASE_DOMAIN="$BASE_DOMAIN"
        export SUBDOMAIN="${SUBDOMAIN:-nextcloud}"
        "$REPO_DIR/setup.sh" --non-interactive
    ) >> "$MAIN_LOG_FILE" 2>&1 &  # Append to preserve history
    local pid=$!

    dialog --title "Initial Setup Log" --tailbox "$MAIN_LOG_FILE" 25 80 &
    local tail_pid=$!

    wait_for_completion "$pid" "Setup in Progress" "Running initial setup... (Check log for details)"
    local exit_code=$?
    
    # Clean up tailbox
    sleep 1
    kill "$tail_pid" 2>/dev/null || true
    reset_terminal
    
    if [ $exit_code -eq 0 ]; then
        dialog --title "Success" --msgbox "Setup completed successfully!" 8 40
    else
        dialog --title "Error" --msgbox "Setup failed. Detailed log saved to:\n\n$MAIN_LOG_FILE" 10 70
    fi
}

# --- Script Entrypoint ---
cd "$REPO_DIR" || { echo "Error: Cannot access $REPO_DIR"; exit 1; }
main_menu