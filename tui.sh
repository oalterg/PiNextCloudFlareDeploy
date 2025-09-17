#!/bin/bash
# tui.sh — A TUI for managing the Nextcloud environment

set -euo pipefail

# --- Configuration ---
REPO_DIR="/opt/raspi-nextcloud-setup"
LOG_DIR="/var/log/raspi-nextcloud"
MAIN_LOG_FILE="$LOG_DIR/main_setup.log"
BACKUP_LOG_FILE="$LOG_DIR/backup.log"
RESTORE_LOG_FILE="$LOG_DIR/restore.log"
ENV_FILE="$REPO_DIR/.env"
COMPOSE_FILE="$REPO_DIR/docker-compose.yml"
CRON_FILE="/etc/cron.d/nextcloud-backup"
HEALTH_LOG_FILE="$LOG_DIR/health_check.log"
HEIGHT=20
WIDTH=70
CHOICE_HEIGHT=8

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
get_nc_cid() {
    docker compose -f "$COMPOSE_FILE" ps -q nextcloud 2>/dev/null || true
}

is_stack_running() {
    [[ -n "$(get_nc_cid)" ]]
}

# Simple wait function (replaces simulated progress bar for user feedback)
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

# Reset terminal after background dialogs (robustness)
reset_terminal() {
    sleep 0.5  # Brief pause for cleanup
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
        sed -i "s/^$key=.*/$key=$value/" "$ENV_FILE"
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

    dialog --title "System Health Check" --tailbox "$HEALTH_LOG_FILE" 25 80
}

# --- TUI Main Functions ---

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

configure_backup_settings() {
    source "$ENV_FILE" 2>/dev/null || true
    local current_retention="${BACKUP_RETENTION:-8}"
    local current_label="${BACKUP_LABEL:-BackupDrive}"
    local current_mount="${BACKUP_MOUNTDIR:-/mnt/backup}"
    local current_format="${AUTO_FORMAT_BACKUP:-false}"

    # Custom schedule form
    local schedule_values
    schedule_values=$(dialog --backtitle "Backup Schedule Configuration" \
        --stdout \
        --title "Configure Backup Time and Day" \
        --form "Enter cron-like schedule (defaults: weekly Sun 03:00):\nMinute (0-59): 0\nHour (0-23): 3\nDay of Month (* or 1-31): *\nMonth (* or 1-12): *\nDay of Week (0-7, 0=Sun): 0" \
        20 70 12 \
        "Minute:"    1 1 "0"     1 20 10 0 \
        "Hour:"      2 1 "3"     2 20 10 0 \
        "Day/Month:" 3 1 "*"     3 20 10 0 \
        "Month:"     4 1 "*"     4 20 10 0 \
        "Day/Week:"  5 1 "0"     5 20 10 0)
    local sched_retval=$?
    if [ $sched_retval -ne 0 ] || [ -z "$schedule_values" ]; then
        return 1  # Canceled
    fi

    mapfile -t sched_array <<< "$schedule_values"
    local new_minute="${sched_array[0]}"
    local new_hour="${sched_array[1]}"
    local new_day_month="${sched_array[2]}"
    local new_month="${sched_array[3]}"
    local new_day_week="${sched_array[4]}"

    # Validate inputs (basic)
    if ! [[ "$new_minute" =~ ^[0-5]?[0-9]$ ]] || ! [[ "$new_hour" =~ ^[0-2]?[0-9]$ ]]; then
        dialog --title "Input Error" --msgbox "Invalid minute/hour. Use 0-59 for minute, 0-23 for hour." 8 60
        return 1
    fi

    # Retention input
    local retention_input
    retention_input=$(dialog --stdout \
        --inputbox "Retention (number of backups to keep, e.g., 7):" 8 50 "$current_retention")
    local ret_retval=$?
    if [ $ret_retval -ne 0 ]; then
        return 1
    fi
    local new_retention="$retention_input"

    # Drive config
    configure_backup_drive "$current_label" "$current_mount" "$current_format"
    local drive_retval=$?
    if [ $drive_retval -ne 0 ]; then
        return 1
    fi

    # Reload .env for updated drive values
    source "$ENV_FILE"

    # Apply changes
    update_env "BACKUP_RETENTION" "$new_retention"
    update_env "BACKUP_MINUTE" "$new_minute"
    update_env "BACKUP_HOUR" "$new_hour"
    update_env "BACKUP_DAY_MONTH" "$new_day_month"
    update_env "BACKUP_MONTH" "$new_month"
    update_env "BACKUP_DAY_WEEK" "$new_day_week"

    install_backup_cron "$new_minute" "$new_hour" "$new_day_month" "$new_month" "$new_day_week"

    dialog --title "Success" --msgbox "Backup settings updated:\nSchedule: $new_minute $new_hour $new_day_month $new_month $new_day_week\nRetention: $new_retention\nDrive: ${BACKUP_LABEL} at ${BACKUP_MOUNTDIR}" 12 70
}

trigger_backup() {
    dialog --title "Confirm Backup" --yesno "Are you sure you want to start a manual backup?" 8 50
    if [ $? -eq 0 ]; then
        (
            "$REPO_DIR/backup.sh"
        ) >> "$BACKUP_LOG_FILE" 2>&1 &  # Append for history
        local pid=$!

        dialog --title "Backup Log" --tailbox "$BACKUP_LOG_FILE" 25 80 &
        local tail_pid=$!

        wait_for_completion "$pid" "Backup in Progress" "Creating backup archive... (Check log for details)"
        local exit_code=$?
        
        kill "$tail_pid" 2>/dev/null || true
        reset_terminal

        if [ $exit_code -eq 0 ]; then
            dialog --title "Success" --msgbox "Backup completed successfully!" 8 40
        else
            dialog --title "Error" --msgbox "Backup failed. Check logs in $BACKUP_LOG_FILE" 8 60
        fi
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

main_menu() {
    while true; do
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
            2 "Scan User Files (files:scan)")
        local retval=$?
        if [ $retval -ne 0 ] || [ "$choice" = "0" ]; then
            return 0  # Explicit back or cancel -> return to main
        fi

        case "$choice" in
            1) toggle_maintenance_mode ;;
            2) run_files_scan ;;
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
            5 "Health Check Log")
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
        esac
        reset_terminal  # Clean after viewing
    done
}

# --- Script Entrypoint ---
cd "$REPO_DIR" || { echo "Error: Cannot access $REPO_DIR"; exit 1; }
main_menu