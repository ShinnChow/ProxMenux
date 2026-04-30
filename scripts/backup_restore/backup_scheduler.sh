#!/bin/bash
# ==========================================================
# ProxMenux - Scheduled Backup Jobs
# ==========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SCRIPTS_LOCAL="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_SCRIPTS_DEFAULT="/usr/local/share/proxmenux/scripts"
LOCAL_SCRIPTS="$LOCAL_SCRIPTS_DEFAULT"
BASE_DIR="/usr/local/share/proxmenux"
UTILS_FILE="$LOCAL_SCRIPTS/utils.sh"

if [[ -f "$LOCAL_SCRIPTS_LOCAL/utils.sh" ]]; then
  LOCAL_SCRIPTS="$LOCAL_SCRIPTS_LOCAL"
  UTILS_FILE="$LOCAL_SCRIPTS/utils.sh"
elif [[ ! -f "$UTILS_FILE" ]]; then
  UTILS_FILE="$BASE_DIR/utils.sh"
fi

if [[ -f "$UTILS_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$UTILS_FILE"
else
  echo "ERROR: utils.sh not found." >&2
  exit 1
fi

LIB_FILE="$SCRIPT_DIR/lib_host_backup_common.sh"
[[ ! -f "$LIB_FILE" ]] && LIB_FILE="$LOCAL_SCRIPTS_DEFAULT/backup_restore/lib_host_backup_common.sh"
if [[ -f "$LIB_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$LIB_FILE"
else
  msg_error "$(translate "Cannot load backup library: lib_host_backup_common.sh")"
  exit 1
fi

load_language
initialize_cache

JOBS_DIR="/var/lib/proxmenux/backup-jobs"
LOG_DIR="/var/log/proxmenux/backup-jobs"
mkdir -p "$JOBS_DIR" "$LOG_DIR" >/dev/null 2>&1 || true

_job_file() { echo "${JOBS_DIR}/$1.env"; }
_job_paths_file() { echo "${JOBS_DIR}/$1.paths"; }
_service_file() { echo "/etc/systemd/system/proxmenux-backup-$1.service"; }
_timer_file() { echo "/etc/systemd/system/proxmenux-backup-$1.timer"; }

_normalize_uint() {
  local v="${1:-0}"
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  echo "$v"
}

_write_job_env() {
  local file="$1"
  shift
  {
    echo "# ProxMenux scheduled backup job"
    local kv key val
    for kv in "$@"; do
      key="${kv%%=*}"
      val="${kv#*=}"
      printf '%s=%q\n' "$key" "$val"
    done
  } > "$file"
}

_list_jobs() {
  local f
  for f in "$JOBS_DIR"/*.env; do
    [[ -f "$f" ]] || continue
    basename "$f" .env
  done | sort
}

_show_job_status() {
  local id="$1"
  local timer_state="disabled"
  local service_state="unknown"
  systemctl is-enabled --quiet "proxmenux-backup-${id}.timer" >/dev/null 2>&1 && timer_state="enabled"
  service_state=$(systemctl is-active "proxmenux-backup-${id}.service" 2>/dev/null || echo "inactive")
  echo "${timer_state}/${service_state}"
}

_write_job_units() {
  local id="$1"
  local on_calendar="$2"
  local runner="$LOCAL_SCRIPTS/backup_restore/run_scheduled_backup.sh"
  [[ ! -f "$runner" ]] && runner="$SCRIPT_DIR/run_scheduled_backup.sh"

  cat > "$(_service_file "$id")" <<EOF
[Unit]
Description=ProxMenux Scheduled Backup Job (${id})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${runner} ${id}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

  cat > "$(_timer_file "$id")" <<EOF
[Unit]
Description=ProxMenux Scheduled Backup Timer (${id})

[Timer]
OnCalendar=${on_calendar}
Persistent=true
RandomizedDelaySec=120
Unit=proxmenux-backup-${id}.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload >/dev/null 2>&1 || true
}

_prompt_retention() {
  local __out_var="$1"
  local last hourly daily weekly monthly yearly
  last=$(dialog --backtitle "ProxMenux" --title "$(translate "Retention")" \
    --inputbox "$(translate "keep-last (0 disables)")" 9 60 "7" 3>&1 1>&2 2>&3) || return 1
  hourly=$(dialog --backtitle "ProxMenux" --title "$(translate "Retention")" \
    --inputbox "$(translate "keep-hourly (0 disables)")" 9 60 "0" 3>&1 1>&2 2>&3) || return 1
  daily=$(dialog --backtitle "ProxMenux" --title "$(translate "Retention")" \
    --inputbox "$(translate "keep-daily (0 disables)")" 9 60 "7" 3>&1 1>&2 2>&3) || return 1
  weekly=$(dialog --backtitle "ProxMenux" --title "$(translate "Retention")" \
    --inputbox "$(translate "keep-weekly (0 disables)")" 9 60 "4" 3>&1 1>&2 2>&3) || return 1
  monthly=$(dialog --backtitle "ProxMenux" --title "$(translate "Retention")" \
    --inputbox "$(translate "keep-monthly (0 disables)")" 9 60 "3" 3>&1 1>&2 2>&3) || return 1
  yearly=$(dialog --backtitle "ProxMenux" --title "$(translate "Retention")" \
    --inputbox "$(translate "keep-yearly (0 disables)")" 9 60 "0" 3>&1 1>&2 2>&3) || return 1

  last=$(_normalize_uint "$last")
  hourly=$(_normalize_uint "$hourly")
  daily=$(_normalize_uint "$daily")
  weekly=$(_normalize_uint "$weekly")
  monthly=$(_normalize_uint "$monthly")
  yearly=$(_normalize_uint "$yearly")

  local -n out="$__out_var"
  out=(
    "KEEP_LAST=$last"
    "KEEP_HOURLY=$hourly"
    "KEEP_DAILY=$daily"
    "KEEP_WEEKLY=$weekly"
    "KEEP_MONTHLY=$monthly"
    "KEEP_YEARLY=$yearly"
  )
}

_create_job() {
  local id backend on_calendar profile_mode
  id=$(dialog --backtitle "ProxMenux" --title "$(translate "New backup job")" \
    --inputbox "$(translate "Job ID (letters, numbers, - _)")" 9 68 "hostcfg-daily" 3>&1 1>&2 2>&3) || return 1
  [[ -z "$id" ]] && return 1
  id=$(echo "$id" | tr -cs '[:alnum:]_-' '-' | sed 's/^-*//; s/-*$//')
  [[ -z "$id" ]] && return 1
  [[ -f "$(_job_file "$id")" ]] && {
    dialog --backtitle "ProxMenux" --title "$(translate "Error")" \
      --msgbox "$(translate "A job with this ID already exists.")" 8 62
    return 1
  }

  backend=$(dialog --backtitle "ProxMenux" --title "$(translate "Backend")" \
    --menu "\n$(translate "Select backup backend:")" 14 70 6 \
    "local" "Local archive" \
    "borg"  "Borg repository" \
    "pbs"   "Proxmox Backup Server" \
    3>&1 1>&2 2>&3) || return 1

  on_calendar=$(dialog --backtitle "ProxMenux" --title "$(translate "Schedule")" \
    --inputbox "$(translate "systemd OnCalendar expression")"$'\n'"$(translate "Example: daily or Mon..Fri 03:00")" \
    11 72 "daily" 3>&1 1>&2 2>&3) || return 1
  [[ -z "$on_calendar" ]] && return 1

  profile_mode=$(dialog --backtitle "ProxMenux" --title "$(translate "Profile")" \
    --menu "\n$(translate "Select backup profile:")" 12 68 4 \
    "default" "Default critical paths" \
    "custom"  "Custom selected paths" \
    3>&1 1>&2 2>&3) || return 1

  local -a paths=()
  hb_select_profile_paths "$profile_mode" paths || return 1

  local -a retention=()
  _prompt_retention retention || return 1

  local -a lines=(
    "JOB_ID=$id"
    "BACKEND=$backend"
    "ON_CALENDAR=$on_calendar"
    "PROFILE_MODE=$profile_mode"
    "ENABLED=1"
  )
  lines+=("${retention[@]}")

  case "$backend" in
    local)
      local dest_dir ext
      dest_dir=$(hb_prompt_dest_dir) || return 1
      ext=$(dialog --backtitle "ProxMenux" --title "$(translate "Archive format")" \
        --menu "\n$(translate "Select local archive format:")" 12 62 4 \
        "tar.zst" "tar + zstd (preferred)" \
        "tar.gz"  "tar + gzip" \
        3>&1 1>&2 2>&3) || return 1
      lines+=("LOCAL_DEST_DIR=$dest_dir" "LOCAL_ARCHIVE_EXT=$ext")
      ;;
    borg)
      local repo passphrase
      hb_select_borg_repo repo || return 1
      hb_prepare_borg_passphrase || return 1
      passphrase="${BORG_PASSPHRASE:-}"
      lines+=(
        "BORG_REPO=$repo"
        "BORG_PASSPHRASE=$passphrase"
        "BORG_ENCRYPT_MODE=${BORG_ENCRYPT_MODE:-none}"
      )
      ;;
    pbs)
      hb_select_pbs_repository || return 1
      hb_ask_pbs_encryption
      local bid
      bid="hostcfg-$(hostname)"
      bid=$(dialog --backtitle "ProxMenux" --title "PBS" \
        --inputbox "$(translate "Backup ID for this job:")" \
        "$HB_UI_INPUT_H" "$HB_UI_INPUT_W" "$bid" 3>&1 1>&2 2>&3) || return 1
      bid=$(echo "$bid" | tr -cs '[:alnum:]_-' '-' | sed 's/-*$//')
      lines+=(
        "PBS_REPOSITORY=${HB_PBS_REPOSITORY}"
        "PBS_PASSWORD=${HB_PBS_SECRET}"
        "PBS_BACKUP_ID=${bid}"
        "PBS_KEYFILE=${HB_PBS_KEYFILE:-}"
        "PBS_ENCRYPTION_PASSWORD=${HB_PBS_ENC_PASS:-}"
      )
      ;;
  esac

  _write_job_env "$(_job_file "$id")" "${lines[@]}"

  : > "$(_job_paths_file "$id")"
  local p
  for p in "${paths[@]}"; do
    echo "$p" >> "$(_job_paths_file "$id")"
  done

  _write_job_units "$id" "$on_calendar"
  systemctl enable --now "proxmenux-backup-${id}.timer" >/dev/null 2>&1 || true

  show_proxmenux_logo
  msg_title "$(translate "Scheduled backup job created")"
  echo -e ""
  echo -e "${TAB}${BGN}$(translate "Job ID:")${CL} ${BL}${id}${CL}"
  echo -e "${TAB}${BGN}$(translate "Backend:")${CL} ${BL}${backend}${CL}"
  echo -e "${TAB}${BGN}$(translate "Schedule:")${CL} ${BL}${on_calendar}${CL}"
  echo -e "${TAB}${BGN}$(translate "Status:")${CL} ${BL}$(_show_job_status "$id")${CL}"
  echo -e ""
  msg_success "$(translate "Press Enter to continue...")"
  read -r
  return 0
}

_pick_job() {
  local title="$1"
  local __out_var="$2"

  local -a ids=()
  mapfile -t ids < <(_list_jobs)
  if [[ ${#ids[@]} -eq 0 ]]; then
    dialog --backtitle "ProxMenux" --title "$(translate "No jobs")" \
      --msgbox "$(translate "No scheduled backup jobs found.")" 8 62
    return 1
  fi

  local -a menu=()
  local i=1 id
  for id in "${ids[@]}"; do
    menu+=("$i" "$id [$(_show_job_status "$id")]")
    ((i++))
  done
  local sel
  sel=$(dialog --backtitle "ProxMenux" --title "$title" \
    --menu "\n$(translate "Select a job:")" "$HB_UI_MENU_H" "$HB_UI_MENU_W" "$HB_UI_MENU_LIST" \
    "${menu[@]}" 3>&1 1>&2 2>&3) || return 1

  local picked="${ids[$((sel-1))]}"
  local -n out="$__out_var"
  out="$picked"
  return 0
}

_job_run_now() {
  local id=""
  _pick_job "$(translate "Run job now")" id || return 1
  local runner="$LOCAL_SCRIPTS/backup_restore/run_scheduled_backup.sh"
  [[ ! -f "$runner" ]] && runner="$SCRIPT_DIR/run_scheduled_backup.sh"
  if "$runner" "$id"; then
    msg_ok "$(translate "Job executed successfully.")"
  else
    msg_warn "$(translate "Job execution finished with errors. Check logs.")"
  fi
  msg_success "$(translate "Press Enter to continue...")"
  read -r
}

_job_toggle() {
  local id=""
  _pick_job "$(translate "Enable/Disable job")" id || return 1
  if systemctl is-enabled --quiet "proxmenux-backup-${id}.timer" >/dev/null 2>&1; then
    systemctl disable --now "proxmenux-backup-${id}.timer" >/dev/null 2>&1 || true
    msg_warn "$(translate "Job timer disabled:") $id"
  else
    systemctl enable --now "proxmenux-backup-${id}.timer" >/dev/null 2>&1 || true
    msg_ok "$(translate "Job timer enabled:") $id"
  fi
  msg_success "$(translate "Press Enter to continue...")"
  read -r
}

_job_delete() {
  local id=""
  _pick_job "$(translate "Delete job")" id || return 1
  if ! whiptail --title "$(translate "Confirm delete")" \
    --yesno "$(translate "Delete scheduled backup job?")"$'\n\n'"ID: ${id}" 10 66; then
    return 1
  fi
  systemctl disable --now "proxmenux-backup-${id}.timer" >/dev/null 2>&1 || true
  rm -f "$(_service_file "$id")" "$(_timer_file "$id")" "$(_job_file "$id")" "$(_job_paths_file "$id")"
  systemctl daemon-reload >/dev/null 2>&1 || true
  msg_ok "$(translate "Job deleted:") $id"
  msg_success "$(translate "Press Enter to continue...")"
  read -r
}

_show_jobs() {
  local tmp
  tmp=$(mktemp) || return
  {
    echo "=== $(translate "Scheduled backup jobs") ==="
    echo ""
    local id
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      echo "• $id   [$(_show_job_status "$id")]"
      if [[ -f "${LOG_DIR}/${id}-last.status" ]]; then
        sed 's/^/    /' "${LOG_DIR}/${id}-last.status"
      fi
      echo ""
    done < <(_list_jobs)
  } > "$tmp"
  dialog --backtitle "ProxMenux" --title "$(translate "Scheduled backup jobs")" \
    --textbox "$tmp" 28 100 || true
  rm -f "$tmp"
}

main_menu() {
  while true; do
    local choice
    choice=$(dialog --backtitle "ProxMenux" \
      --title "$(translate "Backup scheduler and retention")" \
      --menu "\n$(translate "Choose action:")" "$HB_UI_MENU_H" "$HB_UI_MENU_W" "$HB_UI_MENU_LIST" \
      1 "$(translate "Create scheduled backup job")" \
      2 "$(translate "Show jobs and last run status")" \
      3 "$(translate "Run a job now")" \
      4 "$(translate "Enable / disable job timer")" \
      5 "$(translate "Delete job")" \
      0 "$(translate "Return")" \
      3>&1 1>&2 2>&3) || return 0

    case "$choice" in
      1) _create_job ;;
      2) _show_jobs ;;
      3) _job_run_now ;;
      4) _job_toggle ;;
      5) _job_delete ;;
      0) return 0 ;;
    esac
  done
}

main_menu
