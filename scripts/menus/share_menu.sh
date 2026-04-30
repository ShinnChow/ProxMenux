#!/bin/bash
# ==========================================================
# ProxMenux - Network Storage Manager Menu
# ==========================================================
# Author      : MacRimi
# Copyright   : (c) 2024 MacRimi
# License     : MIT
# Version     : 1.2
# Last Updated: $(date +%d/%m/%Y)
# ==========================================================

# Configuration
LOCAL_SCRIPTS="/usr/local/share/proxmenux/scripts"
BASE_DIR="/usr/local/share/proxmenux"
UTILS_FILE="$BASE_DIR/utils.sh"
VENV_PATH="/opt/googletrans-env"

if [[ -f "$UTILS_FILE" ]]; then
    source "$UTILS_FILE"
fi

load_language
initialize_cache

# ==========================================================

while true; do
    OPTION=$(dialog --colors --backtitle "ProxMenux" \
        --title "$(translate "Storage & Share Manager")" \
        --menu "\n$(translate "Select an option:")" 26 78 17 \
            "" "\Z4──────────────────────── HOST ─────────────────────────\Zn" \
            "1"         "$(translate "Configure NFS shared   on Host")" \
            "2"         "$(translate "Configure Samba shared on Host")" \
            "3"         "$(translate "Configure Local Shared on Host")" \
            "4"         "$(translate "Add Local Disk   as Proxmox Storage")" \
            "5"         "$(translate "Add iSCSI Target as Proxmox Storage")" \
            ""          "" \
            ""  "\Z4──────────────────────── LXC ─────────────────────────\Zn" \
            "6"         "$(translate "Configure LXC Mount Points    (Host ↔ Container)")" \
            ""          "" \
            "7"         "$(translate "Configure NFS Client in LXC   (only privileged)")" \
            "8"         "$(translate "Configure Samba Client in LXC (only privileged)")" \
            "9"         "$(translate "Configure NFS Server in LXC   (only privileged)")" \
            "10"        "$(translate "configure Samba Server in LXC (only privileged)")" \
            ""          "" \
            "h"         "$(translate "Help & Info (commands)")" \
            "0"         "$(translate "Return to Main Menu")" \
            2>&1 >/dev/tty
    ) || { exec bash "$LOCAL_SCRIPTS/menus/main_menu.sh"; }

    case "$OPTION" in

        lxctitle|hosttitle)
            continue
            ;;

        1)
            bash "$LOCAL_SCRIPTS/share/nfs_host.sh"
            ;;
        2)
            bash "$LOCAL_SCRIPTS/share/samba_host.sh"
            ;;
        3)
            bash "$LOCAL_SCRIPTS/share/local-shared-manager.sh"
            ;;
        4)
            bash "$LOCAL_SCRIPTS/share/disk_host.sh"
            ;;
        5)
            bash "$LOCAL_SCRIPTS/share/iscsi_host.sh"
            ;;
        6)
            bash "$LOCAL_SCRIPTS/share/lxc-mount-manager_minimal.sh"
            ;;
        7)
            bash "$LOCAL_SCRIPTS/share/nfs_client.sh"
            ;;    
        8) 
            bash "$LOCAL_SCRIPTS/share/samba_client.sh"
            ;;
        9)
            bash "$LOCAL_SCRIPTS/share/nfs_lxc_server.sh"
            ;;
        10)
            bash "$LOCAL_SCRIPTS/share/samba_lxc_server.sh"
            ;;
        h)
            bash "$LOCAL_SCRIPTS/share/commands_share.sh"
            ;;
        0)
            exec bash "$LOCAL_SCRIPTS/menus/main_menu.sh"
            ;;
        *)
            exec bash "$LOCAL_SCRIPTS/menus/main_menu.sh"
            ;;
    esac
done
