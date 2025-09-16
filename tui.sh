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
            4 "View Logs")
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
            1 "Trigger Manual Backup" \
            2 "Restore From Backup")
        local retval=$?
        if [ $retval -ne 0 ] || [ "$choice" = "0" ]; then
            return 0  # Explicit back or cancel -> return to main
        fi

        case "$choice" in
            1) trigger_backup ;;
            2) trigger_restore ;;
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
            4 "Docker Compose Logs")
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
        esac
        reset_terminal  # Clean after viewing
    done
}

# --- Script Entrypoint ---
cd "$REPO_DIR" || { echo "Error: Cannot access $REPO_DIR"; exit 1; }
main_menu