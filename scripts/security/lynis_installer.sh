#!/bin/bash
# ProxMenux - Lynis Security Audit Tool Installer
# ============================================
# Author      : MacRimi
# License     : MIT
# Version     : 1.0
# ============================================
# Hybrid script: works from terminal (dialog) and web panel (ScriptTerminalModal)

SCRIPT_TITLE="Lynis Security Audit Tool Installer"

LOCAL_SCRIPTS="/usr/local/share/proxmenux/scripts"
BASE_DIR="/usr/local/share/proxmenux"
UTILS_FILE="$BASE_DIR/utils.sh"
COMPONENTS_STATUS_FILE="$BASE_DIR/components_status.json"

export BASE_DIR
export COMPONENTS_STATUS_FILE

if [[ -f "$UTILS_FILE" ]]; then
  source "$UTILS_FILE"
fi

if [[ ! -f "$COMPONENTS_STATUS_FILE" ]]; then
  echo "{}" > "$COMPONENTS_STATUS_FILE"
fi

load_language
initialize_cache


# ==========================================================
# Detection
# ==========================================================
detect_lynis() {
  LYNIS_INSTALLED=false
  LYNIS_VERSION=""
  LYNIS_CMD=""

  for path in /usr/local/bin/lynis /opt/lynis/lynis /usr/bin/lynis; do
    if [[ -f "$path" ]] && [[ -x "$path" ]]; then
      LYNIS_CMD="$path"
      break
    fi
  done

  if [[ -n "$LYNIS_CMD" ]]; then
    LYNIS_INSTALLED=true
    LYNIS_VERSION=$("$LYNIS_CMD" show version 2>/dev/null || echo "unknown")
  fi
}


# ==========================================================
# Installation
# ==========================================================
install_lynis() {
  show_proxmenux_logo
  msg_title "$(translate "$SCRIPT_TITLE")"
  msg_info2 "$(translate "Installing latest Lynis security scan tool...")"

  # Install git if needed
  if ! command -v git >/dev/null 2>&1; then
    msg_info "$(translate "Installing Git as a prerequisite...")"
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y git >/dev/null 2>&1
    msg_ok "$(translate "Git installed")"
  fi

  # Remove old installation if present
  if [[ -d /opt/lynis ]]; then
    msg_info "$(translate "Removing previous Lynis installation...")"
    rm -rf /opt/lynis >/dev/null 2>&1
    msg_ok "$(translate "Previous installation removed")"
  fi

  # Clone from GitHub
  msg_info "$(translate "Cloning Lynis from GitHub...")"
  if git clone --quiet https://github.com/CISOfy/lynis.git /opt/lynis >/dev/null 2>&1; then
    # Create wrapper script
    cat << 'EOF' > /usr/local/bin/lynis
#!/bin/bash
cd /opt/lynis && ./lynis "$@"
EOF
    chmod +x /usr/local/bin/lynis
    msg_ok "$(translate "Lynis installed successfully from GitHub")"
  else
    msg_error "$(translate "Failed to clone Lynis from GitHub")"
    return 1
  fi

  # Verify
  if /usr/local/bin/lynis show version >/dev/null 2>&1; then
    local version
    version=$(/usr/local/bin/lynis show version 2>/dev/null)
    update_component_status "lynis" "installed" "$version" "security" '{}'
    msg_ok "$(translate "Lynis version:") $version"
    msg_success "$(translate "Lynis is ready to use")"
  else
    msg_warn "$(translate "Lynis installation could not be verified")"
  fi

  msg_info2 "$(translate "You can run a security audit with:")"
  echo -e "  lynis audit system"
  echo ""
  msg_success "$(translate "Installation completed. Press Enter to continue...")"
  read -r
}


# ==========================================================
# Update
# ==========================================================
update_lynis() {
  show_proxmenux_logo
  msg_title "$(translate "$SCRIPT_TITLE")"
  msg_info2 "$(translate "Updating Lynis to the latest version...")"

  if [[ -d /opt/lynis/.git ]]; then
    cd /opt/lynis
    msg_info "$(translate "Pulling latest changes from GitHub...")"
    if git pull --quiet >/dev/null 2>&1; then
      local version
      version=$(/usr/local/bin/lynis show version 2>/dev/null)
      update_component_status "lynis" "installed" "$version" "security" '{}'
      msg_ok "$(translate "Lynis updated to version:") $version"
    else
      msg_error "$(translate "Failed to update Lynis")"
    fi
  else
    msg_warn "$(translate "Lynis was not installed from Git. Reinstalling...")"
    install_lynis
    return
  fi

  msg_success "$(translate "Update completed. Press Enter to continue...")"
  read -r
}


# ==========================================================
# Run Audit
# ==========================================================
run_audit() {
  show_proxmenux_logo
  msg_title "$(translate "$SCRIPT_TITLE")"
  msg_info2 "$(translate "Running Lynis security audit...")"
  echo ""

  if [[ -z "$LYNIS_CMD" ]]; then
    msg_error "$(translate "Lynis command not found")"
    return 1
  fi

  # Run the audit
  "$LYNIS_CMD" audit system --no-colors 2>&1

  echo ""
  msg_success "$(translate "Audit completed. Press Enter to continue...")"
  read -r
}


# ==========================================================
# Uninstall
# ==========================================================
uninstall_lynis() {
  show_proxmenux_logo
  msg_title "$(translate "$SCRIPT_TITLE")"
  msg_info2 "$(translate "Removing Lynis...")"

  rm -rf /opt/lynis 2>/dev/null
  rm -f /usr/local/bin/lynis 2>/dev/null

  update_component_status "lynis" "removed" "" "security" '{}'

  msg_ok "$(translate "Lynis has been removed")"
  msg_success "$(translate "Uninstallation completed. Press Enter to continue...")"
  read -r
}


# ==========================================================
# Main
# ==========================================================
main() {
  detect_lynis

  if $LYNIS_INSTALLED; then
    # Already installed - show action menu
    local action_text
    action_text="\n$(translate 'Lynis is currently installed.')\n"
    action_text+="$(translate 'Version:') $LYNIS_VERSION\n\n"
    action_text+="$(translate 'What would you like to do?')"

    local ACTION
    ACTION=$(hybrid_menu "$(translate 'Lynis Management')" "$action_text" 20 70 5 \
      "audit" "$(translate 'Run security audit now')" \
      "update" "$(translate 'Update Lynis to latest version')" \
      "reinstall" "$(translate 'Reinstall Lynis')" \
      "remove" "$(translate 'Uninstall Lynis')" \
      "cancel" "$(translate 'Cancel')" \
    ) || ACTION="cancel"

    case "$ACTION" in
      audit)
        run_audit
        ;;
      update)
        update_lynis
        ;;
      reinstall)
        if hybrid_yesno "$(translate 'Reinstall Lynis')" \
          "\n\n$(translate 'This will remove and reinstall Lynis from the latest GitHub source. Continue?')" 12 70; then
          install_lynis
        fi
        ;;
      remove)
        if hybrid_yesno "$(translate 'Remove Lynis')" \
          "\n\n$(translate 'This will completely remove Lynis from the system. Continue?')" 12 70; then
          uninstall_lynis
        fi
        ;;
      cancel|*)
        exit 0
        ;;
    esac
  else
    # Not installed - confirm and install
    local info_text
    info_text="\n$(translate 'Lynis is not installed on this system.')\n\n"
    info_text+="$(translate 'Lynis is a security auditing tool that performs comprehensive system scans including:')\n\n"
    info_text+="  - $(translate 'System hardening scoring (0-100)')\n"
    info_text+="  - $(translate 'Vulnerability detection')\n"
    info_text+="  - $(translate 'Configuration analysis')\n"
    info_text+="  - $(translate 'Compliance checking (PCI-DSS, HIPAA, etc.)')\n\n"
    info_text+="$(translate 'It will be installed from the official GitHub repository.')\n\n"
    info_text+="$(translate 'Do you want to proceed?')"

    if hybrid_yesno "$(translate 'Install Lynis')" "$info_text" 22 70; then
      install_lynis
    else
      exit 0
    fi
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
