#!/usr/bin/env bash

if [[ -n "${__PROXMENUX_PCI_PASSTHROUGH_HELPERS__}" ]]; then
  return 0
fi
__PROXMENUX_PCI_PASSTHROUGH_HELPERS__=1

function _pci_is_iommu_active() {
  grep -qE 'intel_iommu=on|amd_iommu=on' /proc/cmdline 2>/dev/null || return 1
  [[ -d /sys/kernel/iommu_groups ]] || return 1
  find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null | grep -q .
}

# Audio-companion cascade helpers (Part 2 of the SR-IOV / audio rework).
#
# When a GPU is detached from a VM (user chooses "Remove GPU from VM
# config" during a mode switch), the historic sed-based cleanup only
# removes hostpci lines that match the GPU's PCI slot (e.g. 00:02).
# That leaves any "companion" audio that lives at a different slot —
# typically the chipset audio at 00:1f.X, which add_gpu_vm.sh now adds
# alongside an Intel iGPU via the checklist from Part 1 — stranded in
# the VM config. On the next VM start, vfio-pci is no longer claiming
# that audio device (its vendor:device was pulled from vfio.conf
# during the switch-back) and either QEMU fails to rebind it or it
# breaks host audio.
#
# _vm_list_orphan_audio_hostpci reports those stranded entries; each
# caller uses its own UI (dialog, whiptail, hybrid_msgbox) to confirm
# removal and then calls _vm_remove_hostpci_index per selected entry.

# Usage: _vm_list_orphan_audio_hostpci <vmid> <gpu_slot_base>
#   gpu_slot_base: the GPU's PCI slot WITHOUT function suffix, e.g. "00:02".
# Output: one line per orphan entry, in the form "idx|bdf|human_name".
# Empty output when the VM has no audio passthrough outside the GPU slot.
#
# A hostpci audio entry is reported as "orphan" ONLY if the same VM has
# no display/3D-class hostpci at the same slot base. Rationale: the
# audio at e.g. 02:00.1 is the HDMI codec of a dGPU at 02:00.0 — if
# that dGPU is still being passed through to this VM (as a separate
# hostpciN), the audio belongs to it and must not be touched when
# detaching an unrelated GPU (e.g. an Intel iGPU at 00:02.0) from the
# same VM. Without this filter we would strip the HDMI audio of every
# other GPU in the VM, leaving them silent on next start.
function _vm_list_orphan_audio_hostpci() {
  local vmid="$1" gpu_slot="$2"
  [[ -n "$vmid" && -n "$gpu_slot" ]] || return 1
  local conf="/etc/pve/qemu-server/${vmid}.conf"
  [[ -f "$conf" ]] || return 1

  # ── Pass 1 ── collect the slot bases of hostpci entries whose target
  # device is display/3D (class 03xx). These slots "own" any audio at
  # the same slot base (the .1 HDMI codec pattern).
  local -a display_slots=()
  local line raw_bdf bdf class_hex slot_base
  while IFS= read -r line; do
    raw_bdf=$(printf '%s' "$line" \
      | grep -oE '(0000:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]' \
      | head -1)
    [[ -z "$raw_bdf" ]] && continue
    bdf="$raw_bdf"
    [[ "$bdf" =~ ^0000: ]] || bdf="0000:$bdf"
    class_hex=$(cat "/sys/bus/pci/devices/${bdf}/class" 2>/dev/null | sed 's/^0x//')
    if [[ "${class_hex:0:2}" == "03" ]]; then
      slot_base="${bdf#0000:}"
      slot_base="${slot_base%.*}"
      display_slots+=("$slot_base")
    fi
  done < <(grep -E '^hostpci[0-9]+:' "$conf")

  # ── Pass 2 ── classify audio entries.
  local idx raw name
  local has_display_sibling ds
  while IFS= read -r line; do
    idx=$(printf '%s' "$line" | sed -nE 's/^hostpci([0-9]+):.*/\1/p')
    [[ -z "$idx" ]] && continue

    raw=$(printf '%s' "$line" \
      | grep -oE '(0000:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]' \
      | head -1)
    [[ -z "$raw" ]] && continue
    bdf="$raw"
    [[ "$bdf" =~ ^0000: ]] || bdf="0000:$bdf"
    slot_base="${bdf#0000:}"
    slot_base="${slot_base%.*}"

    # Skip entries that match the GPU slot — those go through the
    # caller's primary sed/qm-set cleanup, not through this helper.
    [[ "$slot_base" == "$gpu_slot" ]] && continue

    # Only audio class devices (PCI class 04xx) are candidates.
    class_hex=$(cat "/sys/bus/pci/devices/${bdf}/class" 2>/dev/null | sed 's/^0x//')
    [[ "${class_hex:0:2}" == "04" ]] || continue

    # Display-sibling guard: skip audio that is the HDMI/DP codec of a
    # still-present dGPU in this VM.
    has_display_sibling=false
    for ds in "${display_slots[@]}"; do
      if [[ "$ds" == "$slot_base" ]]; then
        has_display_sibling=true
        break
      fi
    done
    $has_display_sibling && continue

    name=$(lspci -nn -s "${bdf#0000:}" 2>/dev/null \
      | sed 's/^[^ ]* //' \
      | cut -c1-52)
    [[ -z "$name" ]] && name="PCI audio device"

    printf '%s|%s|%s\n' "$idx" "$bdf" "$name"
  done < <(grep -E '^hostpci[0-9]+:' "$conf")
}

# Returns 0 if the given PCI BDF still appears as a hostpci passthrough
# target in any VM config, optionally excluding one or more VM IDs.
# Usage: _pci_bdf_in_any_vm <bdf> [excluded_vmid]...
#
# Used by the switch-mode cascade to decide whether a companion audio
# device's vendor:device pair is safe to remove from /etc/modprobe.d/
# vfio.conf (only if no other VM still references it).
function _pci_bdf_in_any_vm() {
  local bdf="$1"; shift
  [[ -n "$bdf" ]] || return 1
  local short_bdf="${bdf#0000:}"
  local conf vmid ex skip
  for conf in /etc/pve/qemu-server/*.conf; do
    [[ -f "$conf" ]] || continue
    vmid=$(basename "$conf" .conf)
    skip=false
    for ex in "$@"; do
      if [[ "$vmid" == "$ex" ]]; then
        skip=true
        break
      fi
    done
    $skip && continue
    if grep -qE "^hostpci[0-9]+:.*(0000:)?${short_bdf}([,[:space:]]|$)" "$conf" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# Usage: _vm_remove_hostpci_index <vmid> <idx> [log_file]
# Removes hostpci<idx> from the VM config via `qm set --delete` so the
# change goes through Proxmox's own validation path (running VMs get a
# staged update). Returns the exit code of qm set.
function _vm_remove_hostpci_index() {
  local vmid="$1" idx="$2"
  local log="${3:-${LOG_FILE:-/dev/null}}"
  [[ -n "$vmid" && -n "$idx" ]] || return 1
  qm set "$vmid" --delete "hostpci${idx}" >>"$log" 2>&1
}

# Robust LXC stop for switch-mode / passthrough flows.
#
# A plain `pct stop` can hang indefinitely when:
#   - the container has a stale lock from a previous aborted operation,
#   - processes inside the container (Plex, Jellyfin, databases) ignore
#     the initial TERM and sit in uninterruptible-sleep (D state) while
#     the GPU they were using is being yanked out,
#   - the host is under load and Proxmox's state polling stalls,
#   - `pct shutdown --timeout` is not always enforced by pct itself
#     (observed field reports of 5+ min waits despite --timeout 30).
#
# Strategy:
#   1) return 0 immediately if the container is not running,
#   2) clear any stale lock (most common cause of hangs),
#   3) try `pct shutdown --forceStop 1 --timeout 30`, wrapped in an
#      external `timeout 45` as belt-and-braces in case pct itself
#      blocks on backend I/O,
#   4) verify actual status via `pct status` — do not trust exit codes,
#      pct can return non-zero while the container is actually stopped,
#   5) if still running, fall back to `pct stop` wrapped in `timeout 60`,
#   6) verify again and return 1 if the container is truly stuck
#      (only happens when processes are in D state — requires manual
#      intervention, but the wizard moves on instead of hanging).
#
# Usage: _pmx_stop_lxc <ctid> [log_file]
# log_file defaults to $LOG_FILE if set, otherwise /dev/null.
# Returns 0 on stopped / already-stopped, non-zero if every attempt failed.
function _pmx_stop_lxc() {
  local ctid="$1"
  local log="${2:-${LOG_FILE:-/dev/null}}"

  _pmx_lxc_running() {
    pct status "$1" 2>/dev/null | grep -q "status: running"
  }

  _pmx_lxc_running "$ctid" || return 0

  # Best-effort unlock — silent on failure because most containers aren't
  # actually locked; we only care about the cases where they are.
  pct unlock "$ctid" >>"$log" 2>&1 || true

  # Graceful shutdown with forced kill after 30 s. The external `timeout 45`
  # guarantees we never wait longer than that for this step, even if pct
  # itself is stuck (the cushion over 30 s is to let the internal timeout
  # cleanly unwind before we kill pct).
  timeout 45 pct shutdown "$ctid" --forceStop 1 --timeout 30 >>"$log" 2>&1 || true
  sleep 1
  _pmx_lxc_running "$ctid" || return 0

  # Fallback: abrupt stop, also externally capped so the wizard does not
  # hang the user indefinitely if lxc-stop blocks on D-state processes.
  timeout 60 pct stop "$ctid" >>"$log" 2>&1 || true
  sleep 1
  _pmx_lxc_running "$ctid" || return 0

  return 1
}

function _pci_next_hostpci_index() {
  local vmid="$1"
  local idx=0
  local hostpci_existing

  hostpci_existing=$(qm config "$vmid" 2>/dev/null) || return 1
  while grep -q "^hostpci${idx}:" <<< "$hostpci_existing"; do
    idx=$((idx + 1))
  done
  echo "$idx"
}

function _pci_slot_assigned_to_vm() {
  local pci_full="$1"
  local vmid="$2"
  local slot_base
  slot_base="${pci_full#0000:}"
  slot_base="${slot_base%.*}"

  qm config "$vmid" 2>/dev/null \
    | grep -qE "^hostpci[0-9]+:.*(0000:)?${slot_base}(\\.[0-7])?([,[:space:]]|$)"
}

function _pci_function_assigned_to_vm() {
  local pci_full="$1"
  local vmid="$2"
  local bdf slot func pattern
  bdf="${pci_full#0000:}"
  slot="${bdf%.*}"
  func="${bdf##*.}"

  if [[ "$func" == "0" ]]; then
    pattern="^hostpci[0-9]+:.*(0000:)?(${bdf}|${slot})([,:[:space:]]|$)"
  else
    pattern="^hostpci[0-9]+:.*(0000:)?${bdf}([,[:space:]]|$)"
  fi

  qm config "$vmid" 2>/dev/null | grep -qE "$pattern"
}

# ==========================================================
# SR-IOV detection helpers
# ==========================================================
# A PCI device participates in SR-IOV when either:
#   - It is a Physical Function (PF) with one or more active VFs
#     → /sys/bus/pci/devices/<BDF>/sriov_numvfs > 0
#   - It is a Virtual Function (VF) spawned by a PF
#     → /sys/bus/pci/devices/<BDF>/physfn is a symlink to the PF
#
# These helpers accept a BDF in either "0000:00:02.0" or "00:02.0" form.
# Return 0 on match, non-zero otherwise (shell convention).

function _pci_normalize_bdf() {
  local id="$1"
  [[ -z "$id" ]] && return 1
  [[ "$id" =~ ^0000: ]] || id="0000:${id}"
  printf '%s\n' "$id"
}

function _pci_is_vf() {
  local id
  id=$(_pci_normalize_bdf "$1") || return 1
  [[ -L "/sys/bus/pci/devices/${id}/physfn" ]]
}

function _pci_get_pf_of_vf() {
  local id
  id=$(_pci_normalize_bdf "$1") || return 1
  local link="/sys/bus/pci/devices/${id}/physfn"
  [[ -L "$link" ]] || return 1
  basename "$(readlink -f "$link")"
}

function _pci_is_sriov_capable() {
  local id total
  id=$(_pci_normalize_bdf "$1") || return 1
  total=$(cat "/sys/bus/pci/devices/${id}/sriov_totalvfs" 2>/dev/null)
  [[ -n "$total" && "$total" -gt 0 ]]
}

function _pci_active_vf_count() {
  local id num
  id=$(_pci_normalize_bdf "$1") || { echo 0; return 1; }
  num=$(cat "/sys/bus/pci/devices/${id}/sriov_numvfs" 2>/dev/null)
  [[ -n "$num" ]] || num=0
  echo "$num"
}

function _pci_has_active_vfs() {
  local n
  n=$(_pci_active_vf_count "$1")
  [[ "$n" -gt 0 ]]
}

# Filter an array (by name) of PCI BDFs in place, removing entries that
# are SR-IOV Virtual Functions or Physical Functions with active VFs —
# i.e. the configurations ProxMenux refuses to operate on today.
#
# Usage:  _pci_sriov_filter_array <array_name_by_ref>
# Output: one line per removed entry, formatted "BDF|role" where role is
# whatever _pci_sriov_role prints (e.g. "vf 0000:00:02.0" or
# "pf-active 7"). The caller decides how to surface the removals.
# Returns: 0 if the caller should continue (even if some entries were
# filtered); the array mutation happens either way.
function _pci_sriov_filter_array() {
  local -n _arr_ref="$1"
  local -a _kept=()
  local bdf role first
  for bdf in "${_arr_ref[@]}"; do
    role=$(_pci_sriov_role "$bdf" 2>/dev/null)
    first="${role%% *}"
    if [[ "$first" == "vf" || "$first" == "pf-active" ]]; then
      echo "${bdf}|${role}"
    else
      _kept+=("$bdf")
    fi
  done
  _arr_ref=("${_kept[@]}")
}

# Emits a one-line SR-IOV role description for diagnostics/messages.
# Prints one of:
#   "pf-active <N>"      — PF with N>0 active VFs
#   "pf-idle"            — SR-IOV capable PF with 0 VFs (benign)
#   "vf <PF-BDF>"        — VF (names its parent PF)
#   "none"               — device not involved in SR-IOV
function _pci_sriov_role() {
  local id
  id=$(_pci_normalize_bdf "$1") || { echo "none"; return 0; }
  if _pci_is_vf "$id"; then
    echo "vf $(_pci_get_pf_of_vf "$id")"
    return 0
  fi
  if _pci_is_sriov_capable "$id"; then
    local n
    n=$(_pci_active_vf_count "$id")
    if [[ "$n" -gt 0 ]]; then
      echo "pf-active ${n}"
    else
      echo "pf-idle"
    fi
    return 0
  fi
  echo "none"
}
