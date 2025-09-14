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

# --- Ensure scripts are executable ---
chmod +x "$REPO_DIR/setup.sh" "$REPO_DIR/backup.sh" "$REPO_DIR/restore.sh"

# --- Helper Functions ---
get_nc_cid() {
    docker compose -f "$COMPOSE_FILE" ps -q nextcloud 2>/dev/null || true
}

is_stack_running() {
    [[ -n "$(get_nc_cid)" ]]
}

show_progress() {
    local pid=$1
    local title=$2
    local text=$3
    local progress=0

    while [ -d "/proc/$pid" ]; do
        echo "$progress"
        echo -e "XXX\n$progress\n$text\nXXX"
        progress=$(((progress + 5) % 101))
        sleep 0.5
    done | dialog --title "$title" --gauge "$text" 10 70 0

    wait "$pid"
    return $?
}

# --- TUI Main Functions ---

run_initial_setup() {
    # This function will now pass variables to a non-interactive setup script
    exec 3>&1
    local values
    # Run dialog safely (don’t let set -e kill the script)
    if ! values=$(dialog --backtitle "Nextcloud Initial Setup" \
        --title "Configuration" \
        --form "Enter your configuration details below." \
        25 60 16 \
        "Admin Password:"   1 1 ""            1 25 40 0 \
        "DB Root Password:" 2 1 ""            2 25 40 0 \
        "DB User Password:" 3 1 ""            3 25 40 0 \
        "Base Domain:"      4 1 "example.com" 4 25 40 0 \
        "Subdomain:"        5 1 "nextcloud"   5 25 40 0 \
        2>&1 1>&3); then
        exec 3>&-
        echo "[INFO] User canceled or dialog failed at $(date)" >> "$MAIN_LOG_FILE"
        return 1
    fi
    exec 3>&-

    [[ -z "$values" ]] && return # User pressed cancel

    mapfile -t values_array <<< "$values"
    # Validate that we received all expected inputs
    if [ "${#values_array[@]}" -lt 5 ]; then
        dialog --title "Input Error" --msgbox "All fields are required. Please try again." 8 50
        return
    fi

    local ADMIN_PASS="${values_array[0]}"
    local DB_ROOT_PASS="${values_array[1]}"
    local DB_USER_PASS="${values_array[2]}"
    local BASE_DOMAIN="${values_array[3]}"
    local SUBDOMAIN="${values_array[4]}"
    
    # Proactively create and set permissions on the log file to rule out redirection errors
    touch "$MAIN_LOG_FILE"
    chmod 644 "$MAIN_LOG_FILE"

    (
        # Enable verbose tracing and add a marker to see if the subshell starts
        set -x
        echo "--- TUI: Subshell for setup started at $(date) ---"

        # Check for empty variables as a safeguard
        if [[ -z "$ADMIN_PASS" || -z "$DB_ROOT_PASS" || -z "$DB_USER_PASS" || -z "$BASE_DOMAIN" ]]; then
            echo "[FATAL] One or more required variables from the form are empty. Aborting." >&2
            exit 1
        fi

        export NEXTCLOUD_ADMIN_PASSWORD="$ADMIN_PASS"
        export MYSQL_ROOT_PASSWORD="$DB_ROOT_PASS"
        export MYSQL_PASSWORD="$DB_USER_PASS"
        export BASE_DOMAIN="$BASE_DOMAIN"
        export SUBDOMAIN="${SUBDOMAIN:-nextcloud}"
        "$REPO_DIR/setup.sh" --non-interactive
    ) >"$MAIN_LOG_FILE" 2>&1 &
    local pid=$!


    dialog --title "Initial Setup Log" --tailbox "$MAIN_LOG_FILE" 25 80 &
    local tail_pid=$!

    show_progress "$pid" "Setup in Progress" "Running initial setup..."
    local exit_code=$?
    
    # Wait a moment before killing tailbox to ensure final logs are displayed
    sleep 2
    kill "$tail_pid" 2>/dev/null || true
    
    if [ $exit_code -eq 0 ]; then
        dialog --title "Success" --msgbox "Setup completed successfully!" 8 40
    else
        dialog --title "Error" --msgbox "Setup failed. A detailed log has been saved to:\n\n$MAIN_LOG_FILE" 10 70
    fi
}

trigger_backup() {
    dialog --title "Confirm Backup" --yesno "Are you sure you want to start a manual backup?" 8 50
    if [ $? -eq 0 ]; then
        (
            "$REPO_DIR/backup.sh"
        ) >"$BACKUP_LOG_FILE" 2>&1 &
        local pid=$!

        dialog --title "Backup Log" --tailbox "$BACKUP_LOG_FILE" 25 80 &
        local tail_pid=$!

        show_progress $pid "Backup in Progress" "Creating backup archive..."
        local exit_code=$?
        
        kill $tail_pid 2>/dev/null || true

        if [ $exit_code -eq 0 ]; then
            dialog --title "Success" --msgbox "Backup completed successfully!" 8 40
        else
            dialog --title "Error" --msgbox "Backup failed. Check logs in $BACKUP_LOG_FILE" 8 60
        fi
    fi
}

trigger_restore() {
    source "$ENV_FILE" 2>/dev/null || true # Suppress error if file doesn't exist yet
    local backup_dir="${BACKUP_MOUNTDIR:-/mnt/backup}"
    mapfile -t backups < <(find "$backup_dir" -maxdepth 1 -name 'nextcloud_backup_*.tar.gz' -printf "%f\n" 2>/dev/null | sort -r)

    if [ ${#backups[@]} -eq 0 ]; then
        dialog --title "Error" --msgbox "No backup files found in $backup_dir." 8 50
        return
    fi

    local options=()
    for i in "${!backups[@]}"; do
        options+=("$((i+1))" "${backups[$i]}")
    done
    
    exec 3>&1
    local choice
    choice=$(dialog --title "Select Backup to Restore" --menu "Choose a backup file:" $HEIGHT $WIDTH $CHOICE_HEIGHT "${options[@]}" 2>&1 1>&3)
    exec 3>&-

    if [ -n "$choice" ]; then
        local selected_file="${backups[$((choice-1))]}"
        dialog --title "Confirm Restore" --yesno "This will OVERWRITE all current data. Are you absolutely sure you want to restore from:\n\n$selected_file?" 12 60
        if [ $? -eq 0 ]; then
            (
                "$REPO_DIR/restore.sh" "$backup_dir/$selected_file"
            ) >"$RESTORE_LOG_FILE" 2>&1 &
            local pid=$!

            dialog --title "Restore Log" --tailbox "$RESTORE_LOG_FILE" 25 80 &
            local tail_pid=$!

            show_progress $pid "Restore in Progress" "Restoring data from backup..."
            local exit_code=$?
            
            kill $tail_pid 2>/dev/null || true
            
            if [ $exit_code -eq 0 ]; then
                dialog --title "Success" --msgbox "Restore completed successfully!" 8 40
            else
                dialog --title "Error" --msgbox "Restore failed. Check logs in $RESTORE_LOG_FILE" 8 60
            fi
        fi
    fi
}

toggle_maintenance_mode() {
    if ! is_stack_running; then
        dialog --title "Error" --msgbox "Nextcloud stack is not running." 8 50
        return
    fi

    local nc_cid
    nc_cid=$(get_nc_cid)
    local current_status
    current_status=$(docker exec -u www-data "$nc_cid" php occ maintenance:mode)

    local new_mode
    local new_status
    if [[ "$current_status" == *"Maintenance mode is currently enabled"* ]]; then
        new_mode="--off"
        new_status="Disabled"
    else
        new_mode="--on"
        new_status="Enabled"
    fi

    dialog --title "Confirm" --yesno "Maintenance mode is currently ${current_status##*is }. Do you want to turn it ${new_mode##*--}?" 10 60
    if [ $? -eq 0 ]; then
        docker exec -u www-data "$nc_cid" php occ maintenance:mode "$new_mode" > /dev/null
        dialog --title "Success" --msgbox "Maintenance mode is now $new_status." 8 40
    fi
}

run_files_scan() {
    if ! is_stack_running; then
        dialog --title "Error" --msgbox "Nextcloud stack is not running." 8 50
        return
    fi
    
    exec 3>&1
    local user
    user=$(dialog --inputbox "Enter username to scan (or '--all' for all users):" 8 60 "" 2>&1 1>&3)
    exec 3>&-

    if [ -n "$user" ]; then
        dialog --title "Confirm Scan" --yesno "Scan files for user: '$user'?" 8 50
        if [ $? -eq 0 ]; then
            local nc_cid
            nc_cid=$(get_nc_cid)
            (
                echo "Starting file scan for '$user' at $(date)..."
                docker exec -u www-data "$nc_cid" php occ files:scan "$user"
            ) > "$MAIN_LOG_FILE" 2>&1 &
            local pid=$!
            
            dialog --title "File Scan Log" --tailbox "$MAIN_LOG_FILE" 25 80 &
            local tail_pid=$!
            
            show_progress $pid "Scan in Progress" "Scanning user files..."
            kill $tail_pid 2>/dev/null || true
            
            dialog --title "Complete" --msgbox "File scan for '$user' finished. Check log for details." 8 60
        fi
    fi
}

main_menu() {
    while true; do
        exec 3>&1
        local choice
        choice=$(dialog --backtitle "Nextcloud Pi Manager" \
            --title "Main Menu" \
            --cancel-label "Exit" \
            --menu "Select an option:" \
            $HEIGHT $WIDTH $CHOICE_HEIGHT \
            1 "Initial System Setup" \
            2 "Backup/Restore" \
            3 "Maintenance" \
            4 "View Logs" \
            2>&1 1>&3)
        local exit_status=$?
        exec 3>&-

        if [ $exit_status -ne 0 ]; then
            clear
            echo "Exiting."
            exit
        fi

        case "$choice" in
            1) run_initial_setup ;;
            2) backup_restore_menu ;;
            3) maintenance_menu ;;
            4) logs_menu ;;
        esac
    done
}

backup_restore_menu() {
    while true; do
        exec 3>&1
        local choice
        choice=$(dialog --title "Backup/Restore Menu" --cancel-label "Back" \
            --menu "Select an action:" $HEIGHT $WIDTH $CHOICE_HEIGHT \
            1 "Trigger Manual Backup" \
            2 "Restore From Backup" \
            2>&1 1>&3)
        local exit_status=$?
        exec 3>&-
        
        [[ $exit_status -ne 0 ]] && break

        case "$choice" in
            1) trigger_backup ;;
            2) trigger_restore ;;
        esac
    done
}

maintenance_menu() {
    while true; do
        exec 3>&1
        local choice
        choice=$(dialog --title "Maintenance Menu" --cancel-label "Back" \
            --menu "Select an action:" $HEIGHT $WIDTH $CHOICE_HEIGHT \
            1 "Toggle Maintenance Mode" \
            2 "Scan User Files (files:scan)" \
            2>&1 1>&3)
        local exit_status=$?
        exec 3>&-

        [[ $exit_status -ne 0 ]] && break

        case "$choice" in
            1) toggle_maintenance_mode ;;
            2) run_files_scan ;;
        esac
    done
}

logs_menu() {
    while true; do
        exec 3>&1
        local choice
        choice=$(dialog --title "View Logs" --cancel-label "Back" \
            --menu "Select a log to view:" $HEIGHT $WIDTH $CHOICE_HEIGHT \
            1 "Main Setup Log" \
            2 "Backup Log" \
            3 "Restore Log" \
            4 "Docker Compose Logs" \
            2>&1 1>&3)
        local exit_status=$?
        exec 3>&-

        [[ $exit_status -ne 0 ]] && break
        
        case "$choice" in
            1) dialog --title "Setup Log" --tailbox "$MAIN_LOG_FILE" 25 80 ;;
            2) dialog --title "Backup Log" --tailbox "$BACKUP_LOG_FILE" 25 80 ;;
            3) dialog --title "Restore Log" --tailbox "$RESTORE_LOG_FILE" 25 80 ;;
            4) docker compose -f "$COMPOSE_FILE" logs --tail="100" 2>&1 | dialog --title "Docker Logs" --programbox 25 80 ;;
        esac
    done
}


# --- Script Entrypoint ---
cd "$REPO_DIR"
mkdir -p "$LOG_DIR"
main_menu