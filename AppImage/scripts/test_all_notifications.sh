#!/bin/bash
# ============================================================================
# ProxMenux Notification System - Complete Test Suite
# ============================================================================
# 
# Usage:
#   chmod +x test_all_notifications.sh
#   ./test_all_notifications.sh              # Run ALL tests (with 3s pause between)
#   ./test_all_notifications.sh system       # Run only System category
#   ./test_all_notifications.sh vm_ct        # Run only VM/CT category
#   ./test_all_notifications.sh backup       # Run only Backup category
#   ./test_all_notifications.sh resources    # Run only Resources category
#   ./test_all_notifications.sh storage      # Run only Storage category
#   ./test_all_notifications.sh network      # Run only Network category
#   ./test_all_notifications.sh security     # Run only Security category
#   ./test_all_notifications.sh cluster      # Run only Cluster category
#   ./test_all_notifications.sh burst        # Run only Burst aggregation tests
#
# Each test sends a simulated webhook to the local notification endpoint.
# Check your Telegram/Gotify/Discord/Email for the notifications.
# ============================================================================

API="http://127.0.0.1:8008/api/notifications/webhook"
PAUSE=3  # seconds between tests

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

test_count=0
pass_count=0
fail_count=0

send_test() {
    local name="$1"
    local payload="$2"
    test_count=$((test_count + 1))
    
    echo -e "${CYAN}  [$test_count] ${BOLD}$name${NC}"
    
    response=$(curl -s -w "\n%{http_code}" -X POST "$API" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)
    
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | head -n -1)
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "202" ]; then
        echo -e "    ${GREEN}HTTP $http_code${NC} - $body"
        pass_count=$((pass_count + 1))
    else
        echo -e "    ${RED}HTTP $http_code${NC} - $body"
        fail_count=$((fail_count + 1))
    fi
    
    sleep "$PAUSE"
}

# ============================================================================
# SYSTEM CATEGORY (group: system)
# ============================================================================
test_system() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  SYSTEM - Startup, shutdown, kernel${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    
    # 1. state_change (disabled by default -- test to verify it does NOT arrive)
    send_test "state_change (should NOT arrive - disabled by default)" \
        '{"type":"state_change","component":"health","severity":"warning","title":"overall changed to WARNING","body":"overall status changed from OK to WARNING."}'
    
    # 2. new_error
    send_test "new_error" \
        '{"type":"new_error","component":"health","severity":"warning","title":"New WARNING - cpu","body":"CPU usage exceeds 90% for more than 5 minutes","category":"cpu"}'
    
    # 3. error_resolved
    send_test "error_resolved" \
        '{"type":"error_resolved","component":"health","severity":"info","title":"Resolved - cpu","body":"CPU usage returned to normal.\nDuration: 15 minutes","category":"cpu","duration":"15 minutes"}'
    
    # 4. error_escalated
    send_test "error_escalated" \
        '{"type":"error_escalated","component":"health","severity":"critical","title":"Escalated to CRITICAL - memory","body":"Memory usage exceeded 95% and swap is active","category":"memory"}'
    
    # 5. system_shutdown
    send_test "system_shutdown" \
        '{"type":"system_shutdown","component":"system","severity":"warning","title":"System shutting down","body":"The system is shutting down.\nUser initiated shutdown."}'
    
    # 6. system_reboot
    send_test "system_reboot" \
        '{"type":"system_reboot","component":"system","severity":"warning","title":"System rebooting","body":"The system is rebooting.\nKernel update applied."}'
    
    # 7. system_problem
    send_test "system_problem" \
        '{"type":"system_problem","component":"system","severity":"critical","title":"System problem detected","body":"Kernel panic: Attempted to kill init! exitcode=0x00000009"}'
    
    # 8. service_fail
    send_test "service_fail" \
        '{"type":"service_fail","component":"systemd","severity":"warning","title":"Service failed - pvedaemon","body":"Service pvedaemon has failed.\nUnit pvedaemon.service entered failed state.","service_name":"pvedaemon"}'
    
    # 9. update_available (legacy, superseded by update_summary)
    send_test "update_available" \
        '{"type":"update_available","component":"apt","severity":"info","title":"Updates available","body":"Total updates: 12\nSecurity: 3\nProxmox: 5\nKernel: 1\nImportant: pve-manager (8.3.5 -> 8.4.1)","total_count":"12","security_count":"3","pve_count":"5","kernel_count":"1","important_list":"pve-manager (8.3.5 -> 8.4.1)"}'
    
    # 10. update_complete
    send_test "update_complete" \
        '{"type":"update_complete","component":"apt","severity":"info","title":"Update completed","body":"12 packages updated successfully."}'
    
    # 11. unknown_persistent
    send_test "unknown_persistent" \
        '{"type":"unknown_persistent","component":"health","severity":"warning","title":"Check unavailable - temperature","body":"Health check for temperature has been unavailable for 3+ cycles.\nSensor not responding.","category":"temperature"}'
    
    # 12. health_persistent
    send_test "health_persistent" \
        '{"type":"health_persistent","component":"health","severity":"warning","title":"3 active health issue(s)","body":"The following health issues remain active:\n- CPU at 92%\n- Memory at 88%\n- Disk /dev/sda at 94%\n\nThis digest is sent once every 24 hours while issues persist.","count":"3"}'
    
    # 13. health_issue_new
    send_test "health_issue_new" \
        '{"type":"health_issue_new","component":"health","severity":"warning","title":"New health issue - disk","body":"New WARNING issue detected:\nDisk /dev/sda usage at 94%","category":"disk"}'
    
    # 14. health_issue_resolved
    send_test "health_issue_resolved" \
        '{"type":"health_issue_resolved","component":"health","severity":"info","title":"Resolved - disk","body":"disk issue has been resolved.\nDisk usage dropped to 72%.\nDuration: 3 hours","category":"disk","duration":"3 hours"}'
    
    # 15. update_summary
    send_test "update_summary" \
        '{"type":"update_summary","component":"apt","severity":"info","title":"Updates available","body":"Total updates: 70\nSecurity updates: 9\nProxmox-related updates: 24\nKernel updates: 1\nImportant packages: pve-manager (8.3.5 -> 8.4.1), proxmox-ve (8.3.0 -> 8.4.0), qemu-server (8.3.8 -> 8.4.2)","total_count":"70","security_count":"9","pve_count":"24","kernel_count":"1","important_list":"pve-manager (8.3.5 -> 8.4.1), proxmox-ve (8.3.0 -> 8.4.0), qemu-server (8.3.8 -> 8.4.2)"}'
    
    # 16. pve_update
    send_test "pve_update" \
        '{"type":"pve_update","component":"apt","severity":"info","title":"Proxmox VE 8.4.1 available","body":"Proxmox VE 8.3.5 -> 8.4.1\npve-manager 8.3.5 -> 8.4.1","current_version":"8.3.5","new_version":"8.4.1","version":"8.4.1","details":"pve-manager 8.3.5 -> 8.4.1"}'
}

# ============================================================================
# VM / CT CATEGORY (group: vm_ct)
# ============================================================================
test_vm_ct() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  VM / CT - Start, stop, crash, migration${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    
    # 1. vm_start
    send_test "vm_start" \
        '{"type":"vm_start","component":"qemu","severity":"info","title":"VM 100 started","body":"ubuntu-server (100) has been started.","vmid":"100","vmname":"ubuntu-server"}'
    
    # 2. vm_stop
    send_test "vm_stop" \
        '{"type":"vm_stop","component":"qemu","severity":"info","title":"VM 100 stopped","body":"ubuntu-server (100) has been stopped.","vmid":"100","vmname":"ubuntu-server"}'
    
    # 3. vm_shutdown
    send_test "vm_shutdown" \
        '{"type":"vm_shutdown","component":"qemu","severity":"info","title":"VM 100 shutdown","body":"ubuntu-server (100) has been shut down.","vmid":"100","vmname":"ubuntu-server"}'
    
    # 4. vm_fail
    send_test "vm_fail" \
        '{"type":"vm_fail","component":"qemu","severity":"critical","title":"VM 100 FAILED","body":"ubuntu-server (100) has failed.\nKVM: internal error: unexpected exit to hypervisor","vmid":"100","vmname":"ubuntu-server","reason":"KVM: internal error: unexpected exit to hypervisor"}'
    
    # 5. vm_restart
    send_test "vm_restart" \
        '{"type":"vm_restart","component":"qemu","severity":"info","title":"VM 100 restarted","body":"ubuntu-server (100) has been restarted.","vmid":"100","vmname":"ubuntu-server"}'
    
    # 6. ct_start
    send_test "ct_start" \
        '{"type":"ct_start","component":"lxc","severity":"info","title":"CT 200 started","body":"nginx-proxy (200) has been started.","vmid":"200","vmname":"nginx-proxy"}'
    
    # 7. ct_stop
    send_test "ct_stop" \
        '{"type":"ct_stop","component":"lxc","severity":"info","title":"CT 200 stopped","body":"nginx-proxy (200) has been stopped.","vmid":"200","vmname":"nginx-proxy"}'
    
    # 8. ct_fail
    send_test "ct_fail" \
        '{"type":"ct_fail","component":"lxc","severity":"critical","title":"CT 200 FAILED","body":"nginx-proxy (200) has failed.\nContainer exited with error code 137","vmid":"200","vmname":"nginx-proxy","reason":"Container exited with error code 137"}'
    
    # 9. migration_start
    send_test "migration_start" \
        '{"type":"migration_start","component":"qemu","severity":"info","title":"Migration started - 100","body":"ubuntu-server (100) migration to pve-node2 started.","vmid":"100","vmname":"ubuntu-server","target_node":"pve-node2"}'
    
    # 10. migration_complete
    send_test "migration_complete" \
        '{"type":"migration_complete","component":"qemu","severity":"info","title":"Migration complete - 100","body":"ubuntu-server (100) migrated successfully to pve-node2.","vmid":"100","vmname":"ubuntu-server","target_node":"pve-node2"}'
    
    # 11. migration_fail
    send_test "migration_fail" \
        '{"type":"migration_fail","component":"qemu","severity":"critical","title":"Migration FAILED - 100","body":"ubuntu-server (100) migration to pve-node2 failed.\nNetwork timeout during memory transfer","vmid":"100","vmname":"ubuntu-server","target_node":"pve-node2","reason":"Network timeout during memory transfer"}'
    
    # 12. replication_fail
    send_test "replication_fail" \
        '{"type":"replication_fail","component":"replication","severity":"critical","title":"Replication FAILED - 100","body":"Replication of ubuntu-server (100) has failed.\nTarget storage unreachable","vmid":"100","vmname":"ubuntu-server","reason":"Target storage unreachable"}'
    
    # 13. replication_complete
    send_test "replication_complete" \
        '{"type":"replication_complete","component":"replication","severity":"info","title":"Replication complete - 100","body":"Replication of ubuntu-server (100) completed successfully.","vmid":"100","vmname":"ubuntu-server"}'
}

# ============================================================================
# BACKUP CATEGORY (group: backup)
# ============================================================================
test_backup() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  BACKUPS - Backup start, complete, fail${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    
    # 1. backup_start
    send_test "backup_start" \
        '{"type":"backup_start","component":"vzdump","severity":"info","title":"Backup started - 100","body":"Backup of ubuntu-server (100) has started.","vmid":"100","vmname":"ubuntu-server"}'
    
    # 2. backup_complete
    send_test "backup_complete" \
        '{"type":"backup_complete","component":"vzdump","severity":"info","title":"Backup complete - 100","body":"Backup of ubuntu-server (100) completed successfully.\nSize: 12.4 GB","vmid":"100","vmname":"ubuntu-server","size":"12.4 GB"}'
    
    # 3. backup_fail
    send_test "backup_fail" \
        '{"type":"backup_fail","component":"vzdump","severity":"critical","title":"Backup FAILED - 100","body":"Backup of ubuntu-server (100) has failed.\nStorage local-lvm is full","vmid":"100","vmname":"ubuntu-server","reason":"Storage local-lvm is full"}'
    
    # 4. snapshot_complete
    send_test "snapshot_complete" \
        '{"type":"snapshot_complete","component":"qemu","severity":"info","title":"Snapshot created - 100","body":"Snapshot of ubuntu-server (100) created: pre-upgrade-2026","vmid":"100","vmname":"ubuntu-server","snapshot_name":"pre-upgrade-2026"}'
    
    # 5. snapshot_fail
    send_test "snapshot_fail" \
        '{"type":"snapshot_fail","component":"qemu","severity":"critical","title":"Snapshot FAILED - 100","body":"Snapshot of ubuntu-server (100) failed.\nInsufficient space on storage","vmid":"100","vmname":"ubuntu-server","reason":"Insufficient space on storage"}'
}

# ============================================================================
# RESOURCES CATEGORY (group: resources)
# ============================================================================
test_resources() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  RESOURCES - CPU, memory, temperature${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    
    # 1. cpu_high
    send_test "cpu_high" \
        '{"type":"cpu_high","component":"health","severity":"warning","title":"High CPU usage (94%)","body":"CPU usage is at 94% on 16 cores.\nTop process: kvm (VM 100)","value":"94","cores":"16","details":"Top process: kvm (VM 100)"}'
    
    # 2. ram_high
    send_test "ram_high" \
        '{"type":"ram_high","component":"health","severity":"warning","title":"High memory usage (91%)","body":"Memory usage: 58.2 GB / 64 GB (91%).\n4 VMs running, swap at 2.1 GB","value":"91","used":"58.2 GB","total":"64 GB","details":"4 VMs running, swap at 2.1 GB"}'
    
    # 3. temp_high
    send_test "temp_high" \
        '{"type":"temp_high","component":"health","severity":"critical","title":"High temperature (89C)","body":"CPU temperature: 89C (threshold: 80C).\nCheck cooling system immediately","value":"89","threshold":"80","details":"Check cooling system immediately"}'
    
    # 4. load_high
    send_test "load_high" \
        '{"type":"load_high","component":"health","severity":"warning","title":"High system load (24.5)","body":"System load average: 24.5 on 16 cores.\nI/O wait: 35%","value":"24.5","cores":"16","details":"I/O wait: 35%"}'
}

# ============================================================================
# STORAGE CATEGORY (group: storage)
# ============================================================================
test_storage() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  STORAGE - Disk space, I/O errors, SMART${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    
    # 1. disk_space_low
    send_test "disk_space_low" \
        '{"type":"disk_space_low","component":"storage","severity":"warning","title":"Low disk space on /var","body":"/var: 93% used (4.2 GB available).","mount":"/var","used":"93","available":"4.2 GB"}'
    
    # 2. disk_io_error
    send_test "disk_io_error" \
        '{"type":"disk_io_error","component":"smart","severity":"critical","title":"Disk I/O error","body":"I/O error detected on /dev/sdb.\nSMART error: Current Pending Sector Count = 8","device":"/dev/sdb","reason":"SMART error: Current Pending Sector Count = 8"}'
    
    # 3. burst_disk_io
    send_test "burst_disk_io" \
        '{"type":"burst_disk_io","component":"storage","severity":"critical","title":"5 disk I/O errors on /dev/sdb, /dev/sdc","body":"5 I/O errors detected in 60s.\nDevices: /dev/sdb, /dev/sdc","count":"5","window":"60s","entity_list":"/dev/sdb, /dev/sdc"}'
}

# ============================================================================
# NETWORK CATEGORY (group: network)
# ============================================================================
test_network() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  NETWORK - Connectivity, bond, latency${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    
    # 1. network_down
    send_test "network_down" \
        '{"type":"network_down","component":"network","severity":"critical","title":"Network connectivity lost","body":"Network connectivity check failed.\nGateway 192.168.1.1 unreachable. Bond vmbr0 degraded.","reason":"Gateway 192.168.1.1 unreachable. Bond vmbr0 degraded."}'
    
    # 2. network_latency
    send_test "network_latency" \
        '{"type":"network_latency","component":"network","severity":"warning","title":"High network latency (450ms)","body":"Latency to gateway: 450ms (threshold: 100ms).","value":"450","threshold":"100"}'
}

# ============================================================================
# SECURITY CATEGORY (group: security)
# ============================================================================
test_security() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  SECURITY - Auth failures, fail2ban, firewall${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    
    # 1. auth_fail
    send_test "auth_fail" \
        '{"type":"auth_fail","component":"auth","severity":"warning","title":"Authentication failure","body":"Failed login attempt from 203.0.113.42.\nUser: root\nService: sshd","source_ip":"203.0.113.42","username":"root","service":"sshd"}'
    
    # 2. ip_block
    send_test "ip_block" \
        '{"type":"ip_block","component":"security","severity":"info","title":"IP blocked by Fail2Ban","body":"IP 203.0.113.42 has been banned.\nJail: sshd\nFailures: 5","source_ip":"203.0.113.42","jail":"sshd","failures":"5"}'
    
    # 3. firewall_issue
    send_test "firewall_issue" \
        '{"type":"firewall_issue","component":"firewall","severity":"warning","title":"Firewall issue detected","body":"Firewall rule conflict detected on vmbr0.\nRule 15 overlaps with rule 23, potentially blocking cluster traffic.","reason":"Firewall rule conflict detected on vmbr0. Rule 15 overlaps with rule 23."}'
    
    # 4. user_permission_change
    send_test "user_permission_change" \
        '{"type":"user_permission_change","component":"auth","severity":"info","title":"User permission changed","body":"User: admin@pam\nChange: Added PVEAdmin role on /vms/100","username":"admin@pam","change_details":"Added PVEAdmin role on /vms/100"}'
    
    # 5. burst_auth_fail
    send_test "burst_auth_fail" \
        '{"type":"burst_auth_fail","component":"security","severity":"warning","title":"8 auth failures in 2m","body":"8 authentication failures detected in 2m.\nSources: 203.0.113.42, 198.51.100.7, 192.0.2.15","count":"8","window":"2m","entity_list":"203.0.113.42, 198.51.100.7, 192.0.2.15"}'
    
    # 6. burst_ip_block
    send_test "burst_ip_block" \
        '{"type":"burst_ip_block","component":"security","severity":"info","title":"Fail2Ban banned 4 IPs in 5m","body":"4 IPs banned by Fail2Ban in 5m.\nIPs: 203.0.113.42, 198.51.100.7, 192.0.2.15, 10.0.0.99","count":"4","window":"5m","entity_list":"203.0.113.42, 198.51.100.7, 192.0.2.15, 10.0.0.99"}'
}

# ============================================================================
# CLUSTER CATEGORY (group: cluster)
# ============================================================================
test_cluster() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  CLUSTER - Quorum, split-brain, HA fencing${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    
    # 1. split_brain
    send_test "split_brain" \
        '{"type":"split_brain","component":"cluster","severity":"critical","title":"SPLIT-BRAIN detected","body":"Cluster split-brain condition detected.\nQuorum status: No quorum - 1/3 nodes visible","quorum":"No quorum - 1/3 nodes visible"}'
    
    # 2. node_disconnect
    send_test "node_disconnect" \
        '{"type":"node_disconnect","component":"corosync","severity":"critical","title":"Node disconnected","body":"Node pve-node3 has disconnected from the cluster.","node_name":"pve-node3"}'
    
    # 3. node_reconnect
    send_test "node_reconnect" \
        '{"type":"node_reconnect","component":"corosync","severity":"info","title":"Node reconnected","body":"Node pve-node3 has reconnected to the cluster.","node_name":"pve-node3"}'
    
    # 4. burst_cluster
    send_test "burst_cluster" \
        '{"type":"burst_cluster","component":"cluster","severity":"critical","title":"Cluster flapping detected (6 changes)","body":"Cluster state changed 6 times in 5m.\nNodes: pve-node2, pve-node3","count":"6","window":"5m","entity_list":"pve-node2, pve-node3"}'
}

# ============================================================================
# BURST AGGREGATION TESTS (send rapid events to trigger burst detection)
# ============================================================================
test_burst() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  BURST - Rapid events to trigger aggregation${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    
    echo -e "${BLUE}  Sending 5 rapid auth_fail events (should trigger burst_auth_fail)...${NC}"
    for i in $(seq 1 5); do
        curl -s -X POST "$API" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"auth_fail\",\"component\":\"auth\",\"severity\":\"warning\",\"title\":\"Auth fail from 10.0.0.$i\",\"body\":\"Failed login from 10.0.0.$i\",\"source_ip\":\"10.0.0.$i\"}" > /dev/null
        echo -e "    ${CYAN}Sent auth_fail $i/5${NC}"
        sleep 0.5
    done
    echo -e "    ${GREEN}Done. Wait ~10s for burst aggregation...${NC}"
    sleep 10
    
    echo ""
    echo -e "${BLUE}  Sending 4 rapid disk_io_error events (should trigger burst_disk_io)...${NC}"
    for i in $(seq 1 4); do
        curl -s -X POST "$API" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"disk_io_error\",\"component\":\"smart\",\"severity\":\"critical\",\"title\":\"I/O error on /dev/sd${i}\",\"body\":\"Error on device\",\"device\":\"/dev/sd${i}\"}" > /dev/null
        echo -e "    ${CYAN}Sent disk_io_error $i/4${NC}"
        sleep 0.5
    done
    echo -e "    ${GREEN}Done. Wait ~10s for burst aggregation...${NC}"
    sleep 10
    
    echo ""
    echo -e "${BLUE}  Sending 3 rapid node_disconnect events (should trigger burst_cluster)...${NC}"
    for i in $(seq 1 3); do
        curl -s -X POST "$API" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"node_disconnect\",\"component\":\"corosync\",\"severity\":\"critical\",\"title\":\"Node pve-node$i disconnected\",\"body\":\"Node lost\",\"node_name\":\"pve-node$i\"}" > /dev/null
        echo -e "    ${CYAN}Sent node_disconnect $i/3${NC}"
        sleep 0.5
    done
    echo -e "    ${GREEN}Done. Wait ~10s for burst aggregation...${NC}"
    sleep 10
}

# ============================================================================
# MAIN
# ============================================================================

echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  ProxMenux Notification System - Complete Test Suite${NC}"
echo -e "${BOLD}============================================================${NC}"
echo -e "  API: $API"
echo -e "  Pause: ${PAUSE}s between tests"
echo ""

# Check that the service is reachable
status=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8008/api/notifications/status" 2>/dev/null)
if [ "$status" != "200" ]; then
    echo -e "${RED}ERROR: Notification service not reachable (HTTP $status)${NC}"
    echo -e "  Make sure ProxMenux Monitor is running."
    exit 1
fi
echo -e "${GREEN}Service is reachable.${NC}"

# Parse argument
category="${1:-all}"

case "$category" in
    system)     test_system ;;
    vm_ct)      test_vm_ct ;;
    backup)     test_backup ;;
    resources)  test_resources ;;
    storage)    test_storage ;;
    network)    test_network ;;
    security)   test_security ;;
    cluster)    test_cluster ;;
    burst)      test_burst ;;
    all)
        test_system
        test_vm_ct
        test_backup
        test_resources
        test_storage
        test_network
        test_security
        test_cluster
        test_burst
        ;;
    *)
        echo -e "${RED}Unknown category: $category${NC}"
        echo "Usage: $0 [system|vm_ct|backup|resources|storage|network|security|cluster|burst|all]"
        exit 1
        ;;
esac

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  SUMMARY${NC}"
echo -e "${BOLD}============================================================${NC}"
echo -e "  Total tests:  $test_count"
echo -e "  ${GREEN}Accepted:${NC}     $pass_count"
echo -e "  ${RED}Rejected:${NC}     $fail_count"
echo ""
echo -e "  Check your notification channels for the messages."
echo -e "  Note: Some events may be filtered by your current settings"
echo -e "  (severity filter, disabled categories, disabled individual events)."
echo ""
echo -e "  To check notification history (all events):"
echo -e "  ${CYAN}curl -s 'http://127.0.0.1:8008/api/notifications/history?limit=200' | python3 -m json.tool${NC}"
echo ""
echo -e "  To count events by type:"
echo -e "  ${CYAN}curl -s 'http://127.0.0.1:8008/api/notifications/history?limit=200' | python3 -c \"import sys,json; h=json.load(sys.stdin)['history']; [print(f'  {t}: {c}') for t,c in sorted(dict((e['event_type'],sum(1 for x in h if x['event_type']==e['event_type'])) for e in h).items())]\"${NC}
echo ""
