#!/bin/bash
# ============================================================================
# ProxMenux - Real Proxmox Event Simulator
# ============================================================================
# This script triggers ACTUAL events on Proxmox so that PVE's notification
# system fires real webhooks through the full pipeline:
#
#   PVE event -> PVE notification -> webhook POST -> our pipeline -> Telegram
#
# Unlike test_all_notifications.sh (which injects directly via API), this
# script makes Proxmox generate the events itself.
#
# Usage:
#   chmod +x test_real_events.sh
#   ./test_real_events.sh              # interactive menu
#   ./test_real_events.sh disk         # run disk tests only
#   ./test_real_events.sh backup       # run backup tests only
#   ./test_real_events.sh all          # run all tests
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

API="http://127.0.0.1:8008"
LOG_FILE="/tmp/proxmenux_real_test_$(date +%Y%m%d_%H%M%S).log"

# ── Helpers ─────────────────────────────────────────────────────
log() { echo -e "$1" | tee -a "$LOG_FILE"; }
header() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}  $1${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
}

warn() { log "${YELLOW}  [!] $1${NC}"; }
ok()   { log "${GREEN}  [OK] $1${NC}"; }
fail() { log "${RED}  [FAIL] $1${NC}"; }
info() { log "${CYAN}  [i] $1${NC}"; }

confirm() {
    echo ""
    echo -e "${YELLOW}  $1${NC}"
    echo -ne "  Continue? [Y/n]: "
    read -r ans
    [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
}

wait_webhook() {
    local seconds=${1:-10}
    log "  Waiting ${seconds}s for webhook delivery..."
    sleep "$seconds"
}

snapshot_history() {
    curl -s "${API}/api/notifications/history?limit=200" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    count = len(data.get('history', []))
    print(count)
except:
    print(0)
" 2>/dev/null || echo "0"
}

check_new_events() {
    local before=$1
    local after
    after=$(snapshot_history)
    local diff=$((after - before))
    if [ "$diff" -gt 0 ]; then
        ok "Received $diff new notification(s) via webhook"
        # Show the latest events
        curl -s "${API}/api/notifications/history?limit=$((diff + 2))" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for h in data.get('history', [])[:$diff]:
    sev = h.get('severity', '?')
    icon = {'CRITICAL': '  RED', 'WARNING': '  YEL', 'INFO': '  BLU'}.get(sev, '  ???')
    print(f'{icon}  {h[\"event_type\"]:25s}  {h.get(\"title\", \"\")[:60]}')
" 2>/dev/null | tee -a "$LOG_FILE"
    else
        warn "No new notifications detected (may need more time or check filters)"
    fi
}

# ── Pre-flight checks ──────────────────────────────────────────
preflight() {
    header "Pre-flight Checks"
    
    # Check if running as root
    if [ "$(id -u)" -ne 0 ]; then
        fail "This script must be run as root"
        exit 1
    fi
    ok "Running as root"
    
    # Check ProxMenux is running
    if curl -s "${API}/api/health" >/dev/null 2>&1; then
        ok "ProxMenux Monitor is running"
    else
        fail "ProxMenux Monitor not reachable at ${API}"
        exit 1
    fi
    
    # Check webhook is configured by querying PVE directly
    if pvesh get /cluster/notifications/endpoints/webhook --output-format json 2>/dev/null | python3 -c "
import sys, json
endpoints = json.load(sys.stdin)
found = any('proxmenux' in e.get('name','').lower() for e in (endpoints if isinstance(endpoints, list) else [endpoints]))
exit(0 if found else 1)
" 2>/dev/null; then
        ok "PVE webhook endpoint 'proxmenux-webhook' is configured"
    else
        warn "PVE webhook may not be configured. Run setup from the UI first."
        if ! confirm "Continue anyway?"; then
            exit 1
        fi
    fi
    
    # Check notification config
    # API returns { config: { enabled: true/false/'true'/'false', ... }, success: true }
    if curl -s "${API}/api/notifications/settings" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
cfg = d.get('config', d)
enabled = cfg.get('enabled', False)
exit(0 if enabled is True or str(enabled).lower() == 'true' else 1)
" 2>/dev/null; then
        ok "Notifications are enabled"
    else
        fail "Notifications are NOT enabled. Enable them in the UI first."
        exit 1
    fi
    
    # Re-run webhook setup to ensure priv config and body template exist
    info "Re-configuring PVE webhook (ensures priv config + body template)..."
    local setup_result
    setup_result=$(curl -s -X POST "${API}/api/notifications/proxmox/setup-webhook" 2>/dev/null)
    if echo "$setup_result" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('configured') else 1)" 2>/dev/null; then
        ok "PVE webhook re-configured successfully"
    else
        local setup_err
        setup_err=$(echo "$setup_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null)
        warn "Webhook setup returned: ${setup_err}"
        warn "PVE webhook events may not work. Manual commands below:"
        echo "$setup_result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for cmd in d.get('fallback_commands', []):
    print(f'  {cmd}')
" 2>/dev/null
        if ! confirm "Continue anyway?"; then
            exit 1
        fi
    fi
    
    # Find a VM/CT for testing
    VMID=""
    VMNAME=""
    VMTYPE=""
    
    # Try to find a stopped CT first (safest)
    local cts
    cts=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null || echo "[]")
    
    # Look for a stopped container
    VMID=$(echo "$cts" | python3 -c "
import sys, json
vms = json.load(sys.stdin)
# Prefer stopped CTs, then stopped VMs
for v in sorted(vms, key=lambda x: (0 if x.get('type')=='lxc' else 1, 0 if x.get('status')=='stopped' else 1)):
    if v.get('status') == 'stopped':
        print(v.get('vmid', ''))
        break
" 2>/dev/null || echo "")
    
    if [ -n "$VMID" ]; then
        VMTYPE=$(echo "$cts" | python3 -c "
import sys, json
vms = json.load(sys.stdin)
for v in vms:
    if str(v.get('vmid')) == '$VMID':
        print(v.get('type', 'qemu'))
        break
" 2>/dev/null)
        VMNAME=$(echo "$cts" | python3 -c "
import sys, json
vms = json.load(sys.stdin)
for v in vms:
    if str(v.get('vmid')) == '$VMID':
        print(v.get('name', 'unknown'))
        break
" 2>/dev/null)
        ok "Found stopped ${VMTYPE} for testing: ${VMID} (${VMNAME})"
    else
        warn "No stopped VM/CT found. Backup tests will use ID 0 (host backup)."
    fi
    
    # List available storage
    info "Available storage:"
    pvesh get /storage --output-format json 2>/dev/null | python3 -c "
import sys, json
stores = json.load(sys.stdin)
for s in stores:
    sid = s.get('storage', '?')
    stype = s.get('type', '?')
    content = s.get('content', '?')
    print(f'    {sid:20s}  type={stype:10s}  content={content}')
" 2>/dev/null | tee -a "$LOG_FILE" || warn "Could not list storage"
    
    echo ""
    log "  Log file: ${LOG_FILE}"
}

# ============================================================================
#  TEST CATEGORY: DISK ERRORS
# ============================================================================
test_disk() {
    header "DISK ERROR TESTS"
    
    # ── Test D1: SMART error injection ──
    log ""
    log "${BOLD}  Test D1: SMART error log injection${NC}"
    info "Writes a simulated SMART error to syslog so JournalWatcher catches it."
    info "This tests the journal -> notification_events -> pipeline flow."
    
    local before
    before=$(snapshot_history)
    
    # Inject a realistic SMART error into the system journal
    logger -t kernel -p kern.err "ata1.00: exception Emask 0x0 SAct 0x0 SErr 0x0 action 0x6 frozen"
    sleep 1
    logger -t kernel -p kern.crit "ata1.00: failed command: READ FPDMA QUEUED"
    sleep 1
    logger -t smartd -p daemon.warning "Device: /dev/sda [SAT], 1 Currently unreadable (pending) sectors"
    
    wait_webhook 8
    check_new_events "$before"
    
    # ── Test D2: ZFS error simulation ──
    log ""
    log "${BOLD}  Test D2: ZFS scrub error simulation${NC}"
    
    # Check if ZFS is available
    if command -v zpool >/dev/null 2>&1; then
        local zpools
        zpools=$(zpool list -H -o name 2>/dev/null || echo "")
        
        if [ -n "$zpools" ]; then
            local pool
            pool=$(echo "$zpools" | head -1)
            info "ZFS pool found: ${pool}"
            info "Injecting ZFS checksum error into syslog (non-destructive)."
            
            before=$(snapshot_history)
            
            # Simulate ZFS error events via syslog (non-destructive)
            logger -t kernel -p kern.warning "ZFS: pool '${pool}' has experienced an error"
            sleep 1
            logger -t zfs-module -p daemon.err "CHECKSUM error on ${pool}:mirror-0/sda: zio error"
            
            wait_webhook 8
            check_new_events "$before"
        else
            warn "ZFS installed but no pools found. Skipping ZFS test."
        fi
    else
        warn "ZFS not installed. Skipping ZFS test."
    fi
    
    # ── Test D3: Filesystem space pressure ──
    log ""
    log "${BOLD}  Test D3: Disk space pressure simulation${NC}"
    info "Creates a large temporary file to fill disk, triggering space warnings."
    info "The Health Monitor should detect low disk space within ~60s."
    
    # Check current free space on /
    local free_pct
    free_pct=$(df / | tail -1 | awk '{print 100-$5}' | tr -d '%')
    info "Current free space on /: ${free_pct}%"
    
    if [ "$free_pct" -gt 15 ]; then
        info "Disk has ${free_pct}% free. Need to reduce below threshold for test."
        
        # Calculate how much to fill (leave only 8% free)
        local total_k free_k fill_k
        total_k=$(df / | tail -1 | awk '{print $2}')
        free_k=$(df / | tail -1 | awk '{print $4}')
        fill_k=$((free_k - (total_k * 8 / 100)))
        
        if [ "$fill_k" -gt 0 ] && [ "$fill_k" -lt 50000000 ]; then
            info "Will create ${fill_k}KB temp file to simulate low space."
            
            if confirm "This will temporarily fill disk to ~92% on /. Safe to proceed?"; then
                before=$(snapshot_history)
                
                dd if=/dev/zero of=/tmp/.proxmenux_disk_test bs=1024 count="$fill_k" 2>/dev/null || true
                ok "Temp file created. Disk pressure active."
                info "Waiting 90s for Health Monitor to detect low space..."
                
                # Wait for health monitor polling cycle
                for i in $(seq 1 9); do
                    echo -ne "\r  Waiting... ${i}0/90s"
                    sleep 10
                done
                echo ""
                
                # Clean up immediately
                rm -f /tmp/.proxmenux_disk_test
                ok "Temp file removed. Disk space restored."
                
                check_new_events "$before"
            else
                warn "Skipped disk pressure test."
            fi
        else
            warn "Cannot safely fill disk (would need ${fill_k}KB). Skipping."
        fi
    else
        warn "Disk already at ${free_pct}% free. Health Monitor may already be alerting."
    fi
    
    # ── Test D4: I/O error in syslog ──
    log ""
    log "${BOLD}  Test D4: Generic I/O error injection${NC}"
    info "Injects I/O errors into syslog for JournalWatcher."
    
    before=$(snapshot_history)
    
    logger -t kernel -p kern.err "Buffer I/O error on dev sdb1, logical block 0, async page read"
    sleep 1
    logger -t kernel -p kern.err "EXT4-fs error (device sdb1): ext4_find_entry:1455: inode #2: comm ls: reading directory lblock 0"
    
    wait_webhook 8
    check_new_events "$before"
}

# ============================================================================
#  TEST CATEGORY: BACKUP EVENTS
# ============================================================================
test_backup() {
    header "BACKUP EVENT TESTS"
    
    local backup_storage=""
    
    # Find backup-capable storage
    backup_storage=$(pvesh get /storage --output-format json 2>/dev/null | python3 -c "
import sys, json
stores = json.load(sys.stdin)
for s in stores:
    content = s.get('content', '')
    if 'backup' in content or 'vztmpl' in content:
        print(s.get('storage', ''))
        break
# Fallback: try 'local'
else:
    for s in stores:
        if s.get('storage') == 'local':
            print('local')
            break
" 2>/dev/null || echo "local")
    
    info "Using backup storage: ${backup_storage}"
    
    # ── Test B1: Successful vzdump backup ──
    if [ -n "$VMID" ]; then
        log ""
        log "${BOLD}  Test B1: Real vzdump backup (success)${NC}"
        info "Running a real vzdump backup of ${VMTYPE} ${VMID} (${VMNAME})."
        info "This triggers PVE's notification system with a real backup event."
        
        if confirm "This will backup ${VMTYPE} ${VMID} to '${backup_storage}'. Proceed?"; then
            local before
            before=$(snapshot_history)
            
            # Use snapshot mode for VMs (non-disruptive), stop mode for CTs
            local bmode="snapshot"
            if [ "$VMTYPE" = "lxc" ]; then
                bmode="suspend"
            fi
            
            info "Starting vzdump (mode=${bmode}, compress=zstd)..."
            if vzdump "$VMID" --storage "$backup_storage" --mode "$bmode" --compress zstd --notes-template "ProxMenux test backup" 2>&1 | tee -a "$LOG_FILE"; then
                ok "vzdump completed successfully!"
            else
                warn "vzdump returned non-zero (check output above)"
            fi
            
            wait_webhook 12
            check_new_events "$before"
            
            # Clean up the test backup
            info "Cleaning up test backup file..."
            local latest_bak
            latest_bak=$(find "/var/lib/vz/dump/" -name "vzdump-*-${VMID}-*" -type f -newer /tmp/.proxmenux_bak_marker 2>/dev/null | head -1 || echo "")
            # Create a marker for cleanup
            touch /tmp/.proxmenux_bak_marker 2>/dev/null || true
        else
            warn "Skipped backup success test."
        fi
        
        # ── Test B2: Failed vzdump backup ──
        log ""
        log "${BOLD}  Test B2: vzdump backup failure (invalid storage)${NC}"
        info "Attempting backup to non-existent storage to trigger a backup failure event."
        
        before=$(snapshot_history)
        
        # This WILL fail because the storage doesn't exist
        info "Starting vzdump to fake storage (will fail intentionally)..."
        vzdump "$VMID" --storage "nonexistent_storage_12345" --mode snapshot 2>&1 | tail -5 | tee -a "$LOG_FILE" || true
        
        warn "vzdump failed as expected (this is intentional)."
        
        wait_webhook 12
        check_new_events "$before"
        
    else
        warn "No VM/CT available for backup tests."
        info "You can create a minimal LXC container for testing:"
        info "  pct create 9999 local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst --storage local-lvm --memory 128 --cores 1"
    fi
    
    # ── Test B3: Snapshot create/delete ──
    if [ -n "$VMID" ] && [ "$VMTYPE" = "qemu" ]; then
        log ""
        log "${BOLD}  Test B3: VM Snapshot create & delete${NC}"
        info "Creating a snapshot of VM ${VMID} to test snapshot events."
        
        if confirm "Create snapshot 'proxmenux_test' on VM ${VMID}?"; then
            local before
            before=$(snapshot_history)
            
            if qm snapshot "$VMID" proxmenux_test --description "ProxMenux test snapshot" 2>&1 | tee -a "$LOG_FILE"; then
                ok "Snapshot created!"
            else
                warn "Snapshot creation returned non-zero"
            fi
            
            wait_webhook 10
            check_new_events "$before"
            
            # Clean up snapshot
            info "Cleaning up test snapshot..."
            qm delsnapshot "$VMID" proxmenux_test 2>/dev/null || true
            ok "Snapshot removed."
        fi
    elif [ -n "$VMID" ] && [ "$VMTYPE" = "lxc" ]; then
        log ""
        log "${BOLD}  Test B3: CT Snapshot create & delete${NC}"
        info "Creating a snapshot of CT ${VMID}."
        
        if confirm "Create snapshot 'proxmenux_test' on CT ${VMID}?"; then
            local before
            before=$(snapshot_history)
            
            if pct snapshot "$VMID" proxmenux_test --description "ProxMenux test snapshot" 2>&1 | tee -a "$LOG_FILE"; then
                ok "Snapshot created!"
            else
                warn "Snapshot creation returned non-zero"
            fi
            
            wait_webhook 10
            check_new_events "$before"
            
            # Clean up
            info "Cleaning up test snapshot..."
            pct delsnapshot "$VMID" proxmenux_test 2>/dev/null || true
            ok "Snapshot removed."
        fi
    fi
    
    # ── Test B4: PVE scheduled backup notification ──
    log ""
    log "${BOLD}  Test B4: Trigger PVE notification system directly${NC}"
    info "Using 'pvesh create /notifications/endpoints/...' to test PVE's own system."
    info "This sends a test notification through PVE, which should hit our webhook."
    
    local before
    before=$(snapshot_history)
    
    # PVE 8.x has a test endpoint for notifications
    if pvesh create /notifications/targets/test --target proxmenux-webhook 2>&1 | tee -a "$LOG_FILE"; then
        ok "PVE test notification sent!"
    else
        # Try alternative method
        info "Direct test not available. Trying via API..."
        pvesh set /notifications/endpoints/webhook/proxmenux-webhook --test 1 2>/dev/null || \
            warn "Could not send PVE test notification (requires PVE 8.1+)"
    fi
    
    wait_webhook 8
    check_new_events "$before"
}

# ============================================================================
#  TEST CATEGORY: VM/CT LIFECYCLE
# ============================================================================
test_vmct() {
    header "VM/CT LIFECYCLE TESTS"
    
    if [ -z "$VMID" ]; then
        warn "No stopped VM/CT found for lifecycle tests."
        info "Create a minimal CT: pct create 9999 local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst --storage local-lvm --memory 128 --cores 1"
        return
    fi
    
    log ""
    log "${BOLD}  Test V1: Start ${VMTYPE} ${VMID} (${VMNAME})${NC}"
    
    if confirm "Start ${VMTYPE} ${VMID}? It will be stopped again after the test."; then
        local before
        before=$(snapshot_history)
        
        if [ "$VMTYPE" = "lxc" ]; then
            pct start "$VMID" 2>&1 | tee -a "$LOG_FILE" || true
        else
            qm start "$VMID" 2>&1 | tee -a "$LOG_FILE" || true
        fi
        
        ok "Start command sent."
        wait_webhook 10
        check_new_events "$before"
        
        # Wait a moment
        sleep 5
        
        # ── Test V2: Stop ──
        log ""
        log "${BOLD}  Test V2: Stop ${VMTYPE} ${VMID}${NC}"
        
        before=$(snapshot_history)
        
        if [ "$VMTYPE" = "lxc" ]; then
            pct stop "$VMID" 2>&1 | tee -a "$LOG_FILE" || true
        else
            qm stop "$VMID" 2>&1 | tee -a "$LOG_FILE" || true
        fi
        
        ok "Stop command sent."
        wait_webhook 10
        check_new_events "$before"
    fi
}

# ============================================================================
#  TEST CATEGORY: SYSTEM EVENTS (via syslog injection)
# ============================================================================
test_system() {
    header "SYSTEM EVENT TESTS (syslog injection)"
    
    # ── Test S1: Authentication failures ──
    log ""
    log "${BOLD}  Test S1: SSH auth failure injection${NC}"
    info "Injecting SSH auth failure messages into syslog."
    
    local before
    before=$(snapshot_history)
    
    logger -t sshd -p auth.warning "Failed password for root from 192.168.1.200 port 44312 ssh2"
    sleep 2
    logger -t sshd -p auth.warning "Failed password for invalid user admin from 10.0.0.50 port 55123 ssh2"
    sleep 2
    logger -t sshd -p auth.warning "Failed password for root from 192.168.1.200 port 44315 ssh2"
    
    wait_webhook 8
    check_new_events "$before"
    
    # ── Test S2: Firewall event ──
    log ""
    log "${BOLD}  Test S2: Firewall drop event${NC}"
    
    before=$(snapshot_history)
    
    logger -t kernel -p kern.warning "pve-fw-reject: IN=vmbr0 OUT= MAC=00:11:22:33:44:55 SRC=10.0.0.99 DST=192.168.1.1 PROTO=TCP DPT=22 REJECT"
    sleep 2
    logger -t pvefw -p daemon.warning "firewall: blocked incoming connection from 10.0.0.99:45678 to 192.168.1.1:8006"
    
    wait_webhook 8
    check_new_events "$before"
    
    # ── Test S3: Service failure ──
    log ""
    log "${BOLD}  Test S3: Service failure injection${NC}"
    
    before=$(snapshot_history)
    
    logger -t systemd -p daemon.err "pvedaemon.service: Main process exited, code=exited, status=1/FAILURE"
    sleep 1
    logger -t systemd -p daemon.err "Failed to start Proxmox VE API Daemon."
    
    wait_webhook 8
    check_new_events "$before"
}

# ============================================================================
#  SUMMARY & REPORT
# ============================================================================
show_summary() {
    header "TEST SUMMARY"
    
    info "Fetching full notification history..."
    echo ""
    
    curl -s "${API}/api/notifications/history?limit=200" 2>/dev/null | python3 -c "
import sys, json
from collections import Counter

data = json.load(sys.stdin)
history = data.get('history', [])

if not history:
    print('  No notifications in history.')
    sys.exit(0)

# Group by event_type
by_type = Counter(h['event_type'] for h in history)
# Group by severity
by_sev = Counter(h.get('severity', '?') for h in history)
# Group by source
by_src = Counter(h.get('source', '?') for h in history)

print(f'  Total notifications: {len(history)}')
print()

sev_icons = {'CRITICAL': '\033[0;31mCRITICAL\033[0m', 'WARNING': '\033[1;33mWARNING\033[0m', 'INFO': '\033[0;36mINFO\033[0m'}
print('  By severity:')
for sev, count in by_sev.most_common():
    icon = sev_icons.get(sev, sev)
    print(f'    {icon}: {count}')

print()
print('  By source:')
for src, count in by_src.most_common():
    print(f'    {src:20s}: {count}')

print()
print('  By event type:')
for etype, count in by_type.most_common():
    print(f'    {etype:30s}: {count}')

print()
print('  Latest 15 events:')
for h in history[:15]:
    sev = h.get('severity', '?')
    icon = {'CRITICAL': '  \033[0;31mRED\033[0m', 'WARNING': '  \033[1;33mYEL\033[0m', 'INFO': '  \033[0;36mBLU\033[0m'}.get(sev, '  ???')
    ts = h.get('sent_at', '?')[:19]
    src = h.get('source', '?')[:12]
    print(f'    {icon}  {ts}  {src:12s}  {h[\"event_type\"]:25s}  {h.get(\"title\", \"\")[:50]}')
" 2>/dev/null | tee -a "$LOG_FILE"
    
    echo ""
    info "Full log saved to: ${LOG_FILE}"
    echo ""
    info "To see all history:"
    echo -e "  ${CYAN}curl -s '${API}/api/notifications/history?limit=200' | python3 -m json.tool${NC}"
    echo ""
    info "To check Telegram delivery, look at your Telegram bot chat."
}

# ============================================================================
#  INTERACTIVE MENU
# ============================================================================
show_menu() {
    echo ""
    echo -e "${BOLD}  ProxMenux Real Event Test Suite${NC}"
    echo ""
    echo -e "  ${CYAN}1)${NC} Disk error tests      (SMART, ZFS, I/O, space pressure)"
    echo -e "  ${CYAN}2)${NC} Backup tests           (vzdump success/fail, snapshots)"
    echo -e "  ${CYAN}3)${NC} VM/CT lifecycle tests   (start/stop real VMs)"
    echo -e "  ${CYAN}4)${NC} System event tests      (auth, firewall, service failures)"
    echo -e "  ${CYAN}5)${NC} Run ALL tests"
    echo -e "  ${CYAN}6)${NC} Show summary report"
    echo -e "  ${CYAN}q)${NC} Exit"
    echo ""
    echo -ne "  Select: "
}

# ── Main ────────────────────────────────────────────────────────
main() {
    local mode="${1:-menu}"
    
    echo ""
    echo -e "${BOLD}============================================================${NC}"
    echo -e "${BOLD}  ProxMenux - Real Proxmox Event Simulator${NC}"
    echo -e "${BOLD}============================================================${NC}"
    echo -e "  Tests REAL events through the full PVE -> webhook pipeline."
    echo -e "  Log file: ${CYAN}${LOG_FILE}${NC}"
    echo ""
    
    preflight
    
    case "$mode" in
        disk)    test_disk; show_summary ;;
        backup)  test_backup; show_summary ;;
        vmct)    test_vmct; show_summary ;;
        system)  test_system; show_summary ;;
        all)
            test_disk
            test_backup
            test_vmct
            test_system
            show_summary
            ;;
        menu|*)
            while true; do
                show_menu
                read -r choice
                case "$choice" in
                    1) test_disk ;;
                    2) test_backup ;;
                    3) test_vmct ;;
                    4) test_system ;;
                    5) test_disk; test_backup; test_vmct; test_system; show_summary; break ;;
                    6) show_summary ;;
                    q|Q) echo "  Bye!"; break ;;
                    *) warn "Invalid option" ;;
                esac
            done
            ;;
    esac
}

main "${1:-menu}"
