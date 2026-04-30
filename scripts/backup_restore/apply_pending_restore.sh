#!/bin/bash
# ==========================================================
# ProxMenux - Apply Pending Restore On Boot
# ==========================================================

PENDING_BASE="${PMX_RESTORE_PENDING_BASE:-/var/lib/proxmenux/restore-pending}"
CURRENT_LINK="${PENDING_BASE}/current"
LOG_DIR="${PMX_RESTORE_LOG_DIR:-/var/log/proxmenux}"
DEST_PREFIX="${PMX_RESTORE_DEST_PREFIX:-/}"
PRE_BACKUP_BASE="${PMX_RESTORE_PRE_BACKUP_BASE:-/root/proxmenux-pre-restore}"
RECOVERY_BASE="${PMX_RESTORE_RECOVERY_BASE:-/root/proxmenux-recovery}"

mkdir -p "$LOG_DIR" "$PENDING_BASE/completed" >/dev/null 2>&1 || true
LOG_FILE="${LOG_DIR}/proxmenux-restore-onboot-$(date +%Y%m%d_%H%M%S).log"

exec >>"$LOG_FILE" 2>&1

echo "=== ProxMenux pending restore started at $(date -Iseconds) ==="

if [[ ! -e "$CURRENT_LINK" ]]; then
    echo "No pending restore link found. Nothing to do."
    exit 0
fi

PENDING_DIR="$(readlink -f "$CURRENT_LINK" 2>/dev/null || echo "$CURRENT_LINK")"
if [[ ! -d "$PENDING_DIR" ]]; then
    echo "Pending restore directory not found: $PENDING_DIR"
    rm -f "$CURRENT_LINK" >/dev/null 2>&1 || true
    exit 0
fi

APPLY_LIST="${PENDING_DIR}/apply-on-boot.list"
PLAN_ENV="${PENDING_DIR}/plan.env"
STATE_FILE="${PENDING_DIR}/state"

if [[ -f "$PLAN_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$PLAN_ENV"
fi

: "${HB_RESTORE_INCLUDE_ZFS:=0}"

if [[ ! -f "$APPLY_LIST" ]]; then
    echo "Apply list missing: $APPLY_LIST"
    echo "failed" >"$STATE_FILE"
    exit 1
fi

echo "Pending dir: $PENDING_DIR"
echo "Apply list:  $APPLY_LIST"
echo "Include ZFS: $HB_RESTORE_INCLUDE_ZFS"
echo "running" >"$STATE_FILE"

backup_root="${PRE_BACKUP_BASE}/$(date +%Y%m%d_%H%M%S)-onboot"
mkdir -p "$backup_root" >/dev/null 2>&1 || true

cluster_recovery_root=""
applied=0
skipped=0
failed=0

while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue

    src="${PENDING_DIR}/rootfs/${rel}"
    dst="${DEST_PREFIX%/}/${rel}"

    if [[ ! -e "$src" ]]; then
        ((skipped++))
        continue
    fi

    # Never restore cluster virtual filesystem data live.
    if [[ "$rel" == etc/pve* ]] || [[ "$rel" == var/lib/pve-cluster* ]]; then
        if [[ -z "$cluster_recovery_root" ]]; then
            cluster_recovery_root="${RECOVERY_BASE}/$(date +%Y%m%d_%H%M%S)-onboot"
            mkdir -p "$cluster_recovery_root" >/dev/null 2>&1 || true
        fi
        mkdir -p "$cluster_recovery_root/$(dirname "$rel")" >/dev/null 2>&1 || true
        cp -a "$src" "$cluster_recovery_root/$rel" >/dev/null 2>&1 || true
        ((skipped++))
        continue
    fi

    # /etc/zfs is opt-in.
    if [[ "$rel" == etc/zfs || "$rel" == etc/zfs/* ]]; then
        if [[ "$HB_RESTORE_INCLUDE_ZFS" != "1" ]]; then
            ((skipped++))
            continue
        fi
    fi

    if [[ -e "$dst" ]]; then
        mkdir -p "$backup_root/$(dirname "$rel")" >/dev/null 2>&1 || true
        cp -a "$dst" "$backup_root/$rel" >/dev/null 2>&1 || true
    fi

    if [[ -d "$src" ]]; then
        mkdir -p "$dst" >/dev/null 2>&1 || true
        if rsync -aAXH --delete "$src/" "$dst/" >/dev/null 2>&1; then
            ((applied++))
        else
            ((failed++))
        fi
    else
        mkdir -p "$(dirname "$dst")" >/dev/null 2>&1 || true
        if cp -a "$src" "$dst" >/dev/null 2>&1; then
            ((applied++))
        else
            ((failed++))
        fi
    fi
done <"$APPLY_LIST"

systemctl daemon-reload >/dev/null 2>&1 || true
command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u -k all >/dev/null 2>&1 || true
command -v update-grub >/dev/null 2>&1 && update-grub >/dev/null 2>&1 || true

echo "Applied: $applied"
echo "Skipped: $skipped"
echo "Failed:  $failed"
echo "Backup before restore: $backup_root"

if [[ -n "$cluster_recovery_root" ]]; then
    helper="${cluster_recovery_root}/apply-cluster-restore.sh"
    cat > "$helper" <<EOF
#!/bin/bash
set -euo pipefail

RECOVERY_ROOT="${cluster_recovery_root}"
echo "Cluster recovery helper"
echo "Source: \$RECOVERY_ROOT"
echo
echo "WARNING: run this only in a maintenance window."
echo
read -r -p "Type YES to continue: " ans
[[ "\$ans" == "YES" ]] || { echo "Aborted."; exit 1; }

systemctl stop pve-cluster || true
[[ -d "\$RECOVERY_ROOT/etc/pve" ]] && mkdir -p /etc/pve && cp -a "\$RECOVERY_ROOT/etc/pve/." /etc/pve/ || true
[[ -d "\$RECOVERY_ROOT/var/lib/pve-cluster" ]] && mkdir -p /var/lib/pve-cluster && cp -a "\$RECOVERY_ROOT/var/lib/pve-cluster/." /var/lib/pve-cluster/ || true
systemctl start pve-cluster || true
echo "Cluster recovery finished."
EOF
    chmod +x "$helper" >/dev/null 2>&1 || true

    echo "Cluster paths extracted to: $cluster_recovery_root"
    echo "Cluster recovery helper: $helper"
fi

if [[ "$failed" -eq 0 ]]; then
    echo "completed" >"$STATE_FILE"
else
    echo "completed_with_errors" >"$STATE_FILE"
fi

restore_id="$(basename "$PENDING_DIR")"
mv "$PENDING_DIR" "${PENDING_BASE}/completed/${restore_id}" >/dev/null 2>&1 || true
rm -f "$CURRENT_LINK" >/dev/null 2>&1 || true

systemctl disable proxmenux-restore-onboot.service >/dev/null 2>&1 || true

echo "=== ProxMenux pending restore finished at $(date -Iseconds) ==="
echo "Log file: $LOG_FILE"

exit 0
