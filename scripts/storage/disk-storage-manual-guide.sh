#!/bin/bash
# ==========================================================
# ProxMenux - Disk and Storage Manager Manual CLI Guide
# ==========================================================
# Author      : MacRimi
# Copyright   : (c) 2024 MacRimi
# License     : GPL-3.0
# Version     : 1.0
# Last Updated: 07/04/2026
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
    source "$UTILS_FILE"
fi
load_language
initialize_cache

GREEN=$'\033[0;32m'
NC=$'\033[0m'

_cl() {
    local num="$1" disp="$2" desc="$3"
    local pad=$((47 - ${#disp}))
    [[ $pad -lt 1 ]] && pad=1
    local spaces
    spaces=$(printf '%*s' "$pad" '')
    printf " %2d) %s%s%s%s - %s\n" "$num" "$GREEN" "$disp" "$NC" "$spaces" "$desc"
}

while true; do
    clear
    show_proxmenux_logo
    msg_title "$(translate "Disk and Storage Manager - Manual CLI Guide")"
    echo -e "${TAB}${YW}$(translate 'Inspection commands run directly. Template commands [T] require parameter substitution.')${CL}"
    echo

    _cl  1 "lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL" "$(translate 'Inspect disks before any action')"
    _cl  2 "ls -lh /dev/disk/by-id/"                         "$(translate 'Identify persistent disk paths')"
    _cl  3 "qm list && pct list"                             "$(translate 'List VM/CT IDs to operate on')"
    _cl  4 "qm config <vmid> | grep 'sata|scsi|hostpci'"     "$(translate 'Check VM disk/PCI slots')"
    _cl  5 "pvesm status -content images"                    "$(translate 'List storages valid for image import')"
    _cl  6 "qm importdisk <vmid> <image_path> <storage>"     "[T] $(translate 'Import disk image to VM')"
    _cl  7 "qm set <vmid> --<iface><slot> <imported-disk>"   "[T] $(translate 'Attach imported disk to VM')"
    _cl  8 "qm set <vmid> --boot order=<iface><slot>"        "[T] $(translate 'Set VM boot order')"
    _cl  9 "lspci -nn | grep -Ei 'SATA|RAID|NVMe'"           "$(translate 'Detect controller/NVMe BDF')"
    _cl 10 "find /sys/kernel/iommu_groups -type l | grep BDF" "$(translate 'Verify IOMMU group for PCI device')"
    _cl 11 "qm set <vmid> --hostpci<slot> <BDF>,pcie=1"       "[T] $(translate 'Assign controller/NVMe passthrough')"
    _cl 12 "pct config <ctid> | grep '^mp'"                  "$(translate 'Check container mount points')"
    _cl 13 "pct set <ctid> -mp<slot> <disk>,mp=<path>"       "[T] $(translate 'Add disk to LXC container')"
    _cl 14 "wipefs -a -f /dev/sdX && sgdisk --zap-all /dev/sdX" "[T] $(translate 'Clean disk metadata')"
    _cl 15 "parted -s /dev/sdX mklabel gpt mkpart primary"   "[T] $(translate 'Create GPT partition')"
    _cl 16 "mkfs.ext4 -F /dev/sdX1  (or mkfs.xfs / mkfs.btrfs)" "[T] $(translate 'Format filesystem')"
    _cl 17 "pvesm status && zpool status"                    "$(translate 'Final storage health/status check')"
    echo -e " ${DEF} 0) $(translate 'Back to previous menu or Esc + Enter')${CL}"
    echo
    echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter a number, or write or paste a command: ') ${CL}"
    read -r user_input

    if [[ "$user_input" == $'\x1b' ]]; then
        break
    fi

    mode="exec"
    case "$user_input" in
        1) cmd="lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL" ;;
        2) cmd="ls -lh /dev/disk/by-id/" ;;
        3) cmd="qm list && pct list" ;;
        4)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter VM ID: ')${CL}"
            read -r vmid
            cmd="qm config $vmid | grep -E '^(sata|scsi|virtio|ide|hostpci|boot:)'"
            ;;
        5) cmd="pvesm status -content images" ;;
        6)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter VM ID: ')${CL}"; read -r vmid
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter image full path: ')${CL}"; read -r image_path
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter target storage: ')${CL}"; read -r storage
            cmd="qm importdisk $vmid $image_path $storage"
            mode="template"
            ;;
        7)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter VM ID: ')${CL}"; read -r vmid
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter interface (sata/scsi/virtio/ide): ')${CL}"; read -r iface
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter slot number (e.g. 0): ')${CL}"; read -r slot
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter imported disk reference (e.g. local-lvm:vm-100-disk-0): ')${CL}"; read -r imported_disk
            cmd="qm set $vmid --${iface}${slot} $imported_disk"
            mode="template"
            ;;
        8)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter VM ID: ')${CL}"; read -r vmid
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter boot target (e.g. scsi0, sata0, ide0): ')${CL}"; read -r boot_target
            cmd="qm set $vmid --boot order=$boot_target"
            mode="template"
            ;;
        9) cmd="lspci -nn | grep -Ei 'SATA|RAID|Non-Volatile|NVMe'" ;;
        10)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter PCI BDF (e.g. 0000:04:00.0): ')${CL}"
            read -r bdf
            cmd="find /sys/kernel/iommu_groups -type l | grep $bdf"
            ;;
        11)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter VM ID: ')${CL}"; read -r vmid
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter hostpci slot number (e.g. 0): ')${CL}"; read -r slot
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter PCI BDF (e.g. 0000:04:00.0): ')${CL}"; read -r bdf
            cmd="qm set $vmid --hostpci${slot} ${bdf},pcie=1"
            mode="template"
            ;;
        12)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter CT ID: ')${CL}"
            read -r ctid
            cmd="pct config $ctid | grep '^mp'"
            ;;
        13)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter CT ID: ')${CL}"; read -r ctid
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter mp slot number (e.g. 0): ')${CL}"; read -r mpslot
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter disk or partition path (prefer /dev/disk/by-id/...): ')${CL}"; read -r disk_part
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter mount point in CT (e.g. /mnt/data): ')${CL}"; read -r mount_point
            cmd="pct set $ctid -mp${mpslot} ${disk_part},mp=${mount_point},backup=0,ro=0"
            mode="template"
            ;;
        14)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter target disk (e.g. /dev/sdX): ')${CL}"
            read -r disk
            cmd="wipefs -a -f $disk && sgdisk --zap-all $disk"
            mode="template"
            ;;
        15)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter target disk (e.g. /dev/sdX): ')${CL}"
            read -r disk
            cmd="parted -s -f $disk mklabel gpt mkpart primary 1MiB 100%"
            mode="template"
            ;;
        16)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter partition path (e.g. /dev/sdX1): ')${CL}"; read -r part
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter filesystem (ext4/xfs/btrfs): ')${CL}"; read -r fs
            case "$fs" in
                ext4) cmd="mkfs.ext4 -F $part" ;;
                xfs) cmd="mkfs.xfs -f $part" ;;
                btrfs) cmd="mkfs.btrfs -f $part" ;;
                *) cmd="mkfs.ext4 -F $part" ;;
            esac
            mode="template"
            ;;
        17) cmd="pvesm status && zpool status" ;;
        0) break ;;
        *)
            if [[ -n "$user_input" ]]; then
                cmd="$user_input"
            else
                continue
            fi
            ;;
    esac

    if [[ "$mode" == "template" ]]; then
        echo -e "\n${GREEN}$(translate 'Manual command template (copy/paste):')${NC}\n"
        echo "$cmd"
        echo
        msg_success "$(translate 'Press ENTER to continue...')"
        read -r tmp
        continue
    fi

    echo -e "\n${GREEN}> $cmd${NC}\n"
    bash -c "$cmd"
    echo
    msg_success "$(translate 'Press ENTER to continue...')"
    read -r tmp
done

