#!/bin/bash
# ==========================================================
# ProxMenux - GPU/TPU Manual CLI Guide
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
    # _cl <num> <display_cmd> <description>
    # Prints a numbered command line with fixed-column alignment (separator at col 52).
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
    msg_title "$(translate "GPU/TPU - Manual CLI Guide")"
    echo -e "${TAB}${YW}$(translate 'Inspection commands run directly. Template commands [T] require parameter substitution.')${CL}"
    echo

    _cl  1 "lspci -nn | grep -iE 'VGA|3D|Display'"        "$(translate 'Detect GPUs in host')"
    _cl  2 "lspci -nnk | grep -A3 -Ei 'VGA|3D'"           "$(translate 'Show GPU kernel driver in use')"
    _cl  3 "cat /proc/cmdline"                             "$(translate 'Check kernel params (IOMMU flags)')"
    _cl  4 "dmesg -T | grep -Ei 'DMAR|IOMMU|vfio|pcie'"   "$(translate 'Inspect passthrough/kernel events')"
    _cl  5 "find /sys/kernel/iommu_groups -type l"         "$(translate 'List IOMMU group mapping')"
    _cl  6 "lsmod | grep -E 'vfio|nvidia|amdgpu|apex'"     "$(translate 'Check loaded GPU/TPU modules')"
    _cl  7 "grep -R \"vfio-pci|blacklist\" /etc/modprobe.d" "$(translate 'Review passthrough config files')"
    _cl  8 "nvidia-smi"                                    "$(translate 'Check NVIDIA driver and devices')"
    _cl  9 "qm config <vmid> | grep 'hostpci|bios'"        "$(translate 'Check VM passthrough settings')"
    _cl 10 "pct config <ctid> | grep 'dev|lxc.cgroup2'"   "$(translate 'Check LXC GPU/TPU mapping')"
    _cl 11 "ls -l /dev/dri /dev/kfd /dev/nvidia*"          "$(translate 'Inspect host device nodes')"
    _cl 12 "qm set <vmid> --hostpci<slot> <BDF>,pcie=1"    "[T] $(translate 'Assign GPU PCI function to VM')"
    _cl 13 "qm set <vmid> -delete hostpci<slot>"           "[T] $(translate 'Remove passthrough device from VM')"
    _cl 14 "qm set <vmid> -onboot 0"                       "[T] $(translate 'Disable autostart on conflicting VM')"
    _cl 15 "sed -i '/GRUB_CMDLINE_LINUX_DEFAULT/ s|...|'"  "[T] $(translate 'Enable IOMMU in GRUB or ZFS boot')"
    _cl 16 "update-initramfs -u && proxmox-boot-tool"      "[T] $(translate 'Apply boot/initramfs changes')"
    _cl 17 "lsusb | grep Coral ; lspci | grep Unichip"     "$(translate 'Check Coral USB/M.2 detection')"
    echo -e " ${DEF} 0) $(translate 'Back to previous menu or Esc + Enter')${CL}"
    echo
    echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter a number, or write or paste a command: ') ${CL}"
    read -r user_input

    if [[ "$user_input" == $'\x1b' ]]; then
        break
    fi

    mode="exec"
    case "$user_input" in
        1) cmd="lspci -nn | grep -iE 'VGA compatible|3D controller|Display controller'" ;;
        2) cmd="lspci -nnk | grep -A3 -Ei 'VGA compatible|3D controller|Display controller'" ;;
        3) cmd="cat /proc/cmdline" ;;
        4) cmd="dmesg -T | grep -Ei 'DMAR|IOMMU|vfio|pcie|AER|reset'" ;;
        5) cmd="find /sys/kernel/iommu_groups -type l" ;;
        6) cmd="lsmod | grep -E 'vfio|nvidia|amdgpu|i915|apex|gasket'" ;;
        7) cmd="grep -R \"vfio-pci\\|blacklist .*nvidia\\|blacklist .*amdgpu\\|blacklist .*radeon\" /etc/modprobe.d /etc/modules /etc/default/grub /etc/kernel/cmdline 2>/dev/null" ;;
        8) cmd="nvidia-smi" ;;
        9)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter VM ID: ')${CL}"
            read -r vmid
            cmd="qm config $vmid | grep -E '^(hostpci|cpu:|machine:|bios:|args:|boot:)'"
            ;;
        10)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter CT ID: ')${CL}"
            read -r ctid
            cmd="pct config $ctid | grep -E '^(dev[0-9]+:|lxc\\.cgroup2\\.devices\\.allow:|lxc\\.mount\\.entry:|features:)'"
            ;;
        11) cmd="ls -l /dev/dri /dev/kfd /dev/nvidia* /dev/apex* 2>/dev/null" ;;
        12)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter VM ID: ')${CL}"; read -r vmid
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter hostpci slot (e.g. 0): ')${CL}"; read -r slot
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter PCI BDF (e.g. 0000:01:00.0): ')${CL}"; read -r bdf
            cmd="qm set $vmid --hostpci${slot} ${bdf},pcie=1"
            mode="template"
            ;;
        13)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter VM ID: ')${CL}"; read -r vmid
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter hostpci slot (e.g. 0): ')${CL}"; read -r slot
            cmd="qm set $vmid -delete hostpci${slot}"
            mode="template"
            ;;
        14)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Enter VM ID: ')${CL}"; read -r vmid
            cmd="qm set $vmid -onboot 0"
            mode="template"
            ;;
        15)
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'Boot type (grub/zfs): ')${CL}"; read -r boot_type
            echo -en "${TAB}${BOLD}${YW}${HOLD}$(translate 'CPU vendor (intel/amd): ')${CL}"; read -r cpu_vendor
            case "$cpu_vendor" in
                amd|AMD) iommu_param="amd_iommu=on iommu=pt" ;;
                *)       iommu_param="intel_iommu=on iommu=pt" ;;
            esac
            case "$boot_type" in
                zfs|ZFS) cmd="sed -i 's/\$/ ${iommu_param}/' /etc/kernel/cmdline" ;;
                *)       cmd="sed -i '/GRUB_CMDLINE_LINUX_DEFAULT=/ s|\"$| ${iommu_param}\"|' /etc/default/grub" ;;
            esac
            mode="template"
            ;;
        16)
            cmd="update-initramfs -u -k all && (proxmox-boot-tool refresh || update-grub)"
            mode="template"
            ;;
        17) cmd="lsusb | grep -Ei '18d1:9302|1a6e:089a' ; lspci | grep -i 'Global Unichip'" ;;
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

