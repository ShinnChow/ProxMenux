#!/usr/bin/env bash

if [[ -n "${__PROXMENUX_GPU_HOOK_GUARD_HELPERS__}" ]]; then
  return 0
fi
__PROXMENUX_GPU_HOOK_GUARD_HELPERS__=1

PROXMENUX_GPU_HOOK_STORAGE_REF="local:snippets/proxmenux-gpu-guard.sh"
PROXMENUX_GPU_HOOK_ABS_PATH="/var/lib/vz/snippets/proxmenux-gpu-guard.sh"

_gpu_guard_msg_warn() {
  if declare -F msg_warn >/dev/null 2>&1; then
    msg_warn "$1"
  else
    echo "[WARN] $1" >&2
  fi
}

_gpu_guard_msg_ok() {
  if declare -F msg_ok >/dev/null 2>&1; then
    msg_ok "$1"
  else
    echo "[OK] $1"
  fi
}

_gpu_guard_has_vm_gpu() {
  local vmid="$1"
  qm config "$vmid" 2>/dev/null | grep -qE '^hostpci[0-9]+:'
}

_gpu_guard_has_lxc_gpu() {
  local ctid="$1"
  local conf="/etc/pve/lxc/${ctid}.conf"
  [[ -f "$conf" ]] || return 1
  grep -qE 'dev[0-9]+:.*(/dev/dri|/dev/nvidia|/dev/kfd)|lxc\.mount\.entry:.*dev/dri' "$conf" 2>/dev/null
}

ensure_proxmenux_gpu_guard_hookscript() {
  mkdir -p /var/lib/vz/snippets 2>/dev/null || true

  cat >"$PROXMENUX_GPU_HOOK_ABS_PATH" <<'HOOKEOF'
#!/usr/bin/env bash
set -u

arg1="${1:-}"
arg2="${2:-}"
case "$arg1" in
  pre-start|post-start|pre-stop|post-stop)
    phase="$arg1"
    guest_id="$arg2"
    ;;
  *)
    guest_id="$arg1"
    phase="$arg2"
    ;;
esac
[[ "$phase" == "pre-start" ]] || exit 0

vm_conf="/etc/pve/qemu-server/${guest_id}.conf"
ct_conf="/etc/pve/lxc/${guest_id}.conf"

if [[ -f "$vm_conf" ]]; then
  mapfile -t hostpci_lines < <(grep -E '^hostpci[0-9]+:' "$vm_conf" 2>/dev/null || true)
  [[ ${#hostpci_lines[@]} -eq 0 ]] && exit 0

  # Build slot list used by this VM and block if any running VM already uses same slot.
  slot_keys=()
  for line in "${hostpci_lines[@]}"; do
    val="${line#*: }"
    [[ "$val" == *"mapping="* ]] && continue
    first_field="${val%%,*}"
    IFS=';' read -r -a ids <<< "$first_field"
    for id in "${ids[@]}"; do
      id="${id#host=}"
      id="${id// /}"
      [[ -z "$id" ]] && continue
      if [[ "$id" =~ ^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}$ ]]; then
        key="${id,,}"
      else
        [[ "$id" =~ ^0000: ]] || id="0000:${id}"
        key="${id#0000:}"
        key="${key%.*}"
        key="${key,,}"
      fi
      dup=0
      for existing in "${slot_keys[@]}"; do
        [[ "$existing" == "$key" ]] && dup=1 && break
      done
      [[ "$dup" -eq 0 ]] && slot_keys+=("$key")
    done
  done

  if [[ ${#slot_keys[@]} -gt 0 ]]; then
    conflict_details=""
    for other_conf in /etc/pve/qemu-server/*.conf; do
      [[ -f "$other_conf" ]] || continue
      other_vmid="$(basename "$other_conf" .conf)"
      [[ "$other_vmid" == "$guest_id" ]] && continue
      qm status "$other_vmid" 2>/dev/null | grep -q "status: running" || continue

      for key in "${slot_keys[@]}"; do
        if grep -qE "^hostpci[0-9]+:.*(0000:)?${key}(\\.[0-7])?([,[:space:]]|$)" "$other_conf" 2>/dev/null; then
          other_name="$(awk '/^name:/ {print $2}' "$other_conf" 2>/dev/null)"
          [[ -z "$other_name" ]] && other_name="VM-${other_vmid}"
          conflict_details+=$'\n'"- ${key} in use by VM ${other_vmid} (${other_name})"
          break
        fi
      done
    done

    if [[ -n "$conflict_details" ]]; then
      echo "ProxMenux GPU Guard: VM ${guest_id} blocked at pre-start." >&2
      echo "A hostpci device slot is already in use by another running VM." >&2
      printf '%s\n' "$conflict_details" >&2
      echo "Stop the source VM or remove/move the shared hostpci assignment." >&2
      exit 1
    fi
  fi

  failed=0
  details=""
  for line in "${hostpci_lines[@]}"; do
    val="${line#*: }"
    [[ "$val" == *"mapping="* ]] && continue

    first_field="${val%%,*}"
    IFS=';' read -r -a ids <<< "$first_field"
    for id in "${ids[@]}"; do
      id="${id#host=}"
      id="${id// /}"
      [[ -z "$id" ]] && continue

      # Slot-only syntax (e.g. 01:00 or 0000:01:00) is accepted by Proxmox.
      if [[ "$id" =~ ^([0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}$ ]]; then
        slot="${id,,}"
        slot="${slot#0000:}"
        slot_has_gpu=false
        for dev in /sys/bus/pci/devices/0000:${slot}.*; do
          [[ -e "$dev" ]] || continue
          # SR-IOV: skip Virtual Functions when iterating a whole slot.
          # VFs share the slot with their PF but carry their own driver
          # state; their vfio-pci rebind is handled by Proxmox at VM
          # start. Pre-flighting them would falsely block SR-IOV setups
          # where the PF legitimately stays on the native driver.
          [[ -L "${dev}/physfn" ]] && continue
          class_hex="$(cat "$dev/class" 2>/dev/null | sed 's/^0x//')"
          [[ "${class_hex:0:2}" != "03" ]] && continue
          slot_has_gpu=true
          drv="$(basename "$(readlink "$dev/driver" 2>/dev/null)" 2>/dev/null)"
          if [[ "$drv" != "vfio-pci" ]]; then
            failed=1
            details+=$'\n'"- ${dev##*/}: driver=${drv:-none}"
          fi
        done
        # If this slot does not include a display/3D controller, it is not GPU-guarded.
        [[ "$slot_has_gpu" == "true" ]] || true
        continue
      fi

      [[ "$id" =~ ^0000: ]] || id="0000:${id}"
      dev_path="/sys/bus/pci/devices/${id}"
      if [[ ! -d "$dev_path" ]]; then
        failed=1
        details+=$'\n'"- ${id}: PCI device not found"
        continue
      fi
      # SR-IOV VF: do not pre-flight the driver. Proxmox rebinds the VF
      # to vfio-pci as part of VM start; at pre-start time the VF may
      # still be on its native driver (i915, etc.) — that is normal,
      # not an error. Blocking here would prevent every SR-IOV VF
      # passthrough from starting.
      if [[ -L "${dev_path}/physfn" ]]; then
        continue
      fi
      class_hex="$(cat "$dev_path/class" 2>/dev/null | sed 's/^0x//')"
      # Enforce vfio only for display/3D devices (PCI class 03xx).
      [[ "${class_hex:0:2}" == "03" ]] || continue
      drv="$(basename "$(readlink "$dev_path/driver" 2>/dev/null)" 2>/dev/null)"
      if [[ "$drv" != "vfio-pci" ]]; then
        failed=1
        details+=$'\n'"- ${id}: driver=${drv:-none}"
      fi
    done
  done

  if [[ "$failed" -eq 1 ]]; then
    echo "ProxMenux GPU Guard: VM ${guest_id} blocked at pre-start." >&2
    echo "GPU passthrough device is not ready for VM mode (vfio-pci required)." >&2
    printf '%s\n' "$details" >&2
    echo "Switch mode to GPU -> VM from ProxMenux: GPUs and Coral-TPU Menu." >&2
    exit 1
  fi
  exit 0
fi

if [[ -f "$ct_conf" ]]; then
  mapfile -t gpu_dev_paths < <(
    {
      grep -E '^dev[0-9]+:' "$ct_conf" 2>/dev/null | sed -E 's/^dev[0-9]+:[[:space:]]*([^,[:space:]]+).*/\1/'
      grep -E '^lxc\.mount\.entry:' "$ct_conf" 2>/dev/null | sed -E 's/^lxc\.mount\.entry:[[:space:]]*([^[:space:]]+).*/\1/'
    } | grep -E '^/dev/(dri|nvidia|kfd)' | sort -u
  )

  [[ ${#gpu_dev_paths[@]} -eq 0 ]] && exit 0

  missing=""
  for dev in "${gpu_dev_paths[@]}"; do
    [[ -e "$dev" ]] || missing+=$'\n'"- ${dev} unavailable"
  done

  if [[ -n "$missing" ]]; then
    echo "ProxMenux GPU Guard: LXC ${guest_id} blocked at pre-start." >&2
    echo "Configured GPU devices are unavailable in host device nodes." >&2
    printf '%s\n' "$missing" >&2
    echo "Switch mode to GPU -> LXC from ProxMenux: GPUs and Coral-TPU Menu." >&2
    exit 1
  fi
  exit 0
fi

exit 0
HOOKEOF

  chmod 755 "$PROXMENUX_GPU_HOOK_ABS_PATH" 2>/dev/null || true
}

attach_proxmenux_gpu_guard_to_vm() {
  local vmid="$1"
  _gpu_guard_has_vm_gpu "$vmid" || return 0

  local current
  current=$(qm config "$vmid" 2>/dev/null | awk '/^hookscript:/ {print $2}')
  if [[ "$current" == "$PROXMENUX_GPU_HOOK_STORAGE_REF" ]]; then
    return 0
  fi

  if qm set "$vmid" --hookscript "$PROXMENUX_GPU_HOOK_STORAGE_REF" >/dev/null 2>&1; then
    _gpu_guard_msg_ok "PCIe passthrough guard attached to VM ${vmid}"
  else
    _gpu_guard_msg_warn "Could not attach PCIe passthrough guard to VM ${vmid}. Ensure 'local' storage supports snippets."
  fi
}

attach_proxmenux_gpu_guard_to_lxc() {
  local ctid="$1"
  _gpu_guard_has_lxc_gpu "$ctid" || return 0

  local current
  current=$(pct config "$ctid" 2>/dev/null | awk '/^hookscript:/ {print $2}')
  if [[ "$current" == "$PROXMENUX_GPU_HOOK_STORAGE_REF" ]]; then
    return 0
  fi

  if pct set "$ctid" -hookscript "$PROXMENUX_GPU_HOOK_STORAGE_REF" >/dev/null 2>&1; then
    _gpu_guard_msg_ok "PCIe passthrough guard attached to LXC ${ctid}"
  else
    _gpu_guard_msg_warn "Could not attach PCIe passthrough guard to LXC ${ctid}. Ensure 'local' storage supports snippets."
  fi
}

sync_proxmenux_gpu_guard_hooks() {
  ensure_proxmenux_gpu_guard_hookscript

  local vmid ctid
  for conf in /etc/pve/qemu-server/*.conf; do
    [[ -f "$conf" ]] || continue
    vmid=$(basename "$conf" .conf)
    _gpu_guard_has_vm_gpu "$vmid" && attach_proxmenux_gpu_guard_to_vm "$vmid"
  done

  for conf in /etc/pve/lxc/*.conf; do
    [[ -f "$conf" ]] || continue
    ctid=$(basename "$conf" .conf)
    _gpu_guard_has_lxc_gpu "$ctid" && attach_proxmenux_gpu_guard_to_lxc "$ctid"
  done
}
