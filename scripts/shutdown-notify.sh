#!/bin/bash
# ProxMenux Monitor - Shutdown Notification Script
# This script is called by systemd ExecStop before the service terminates.
# It sends a shutdown/reboot notification ONLY when the system is actually
# shutting down or rebooting, NOT when the service is manually stopped.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/var/lib/proxmenux"
CONFIG_FILE="$CONFIG_DIR/config.json"
LOG_FILE="/var/log/proxmenux-shutdown.log"
PORT="${PORT:-8008}"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

log "=== Shutdown notification script started ==="

# Check if this is a real system shutdown/reboot or just a service stop
# We only want to notify on actual system shutdown/reboot
is_system_shutdown=false
is_reboot=false

# Method 1: Check systemd system state (most reliable)
# "stopping" means the system is shutting down
system_state=$(systemctl is-system-running 2>/dev/null)
if [ "$system_state" = "stopping" ]; then
    is_system_shutdown=true
    log "Detected: systemctl is-system-running = stopping"
fi

# Method 2: Check systemd jobs queue for shutdown/reboot jobs
jobs_output=$(systemctl list-jobs 2>/dev/null)
if echo "$jobs_output" | grep -qE "reboot\.target.*(start|waiting)"; then
    is_system_shutdown=true
    is_reboot=true
    log "Detected: reboot.target job in queue"
elif echo "$jobs_output" | grep -qE "(shutdown|poweroff|halt)\.target.*(start|waiting)"; then
    is_system_shutdown=true
    log "Detected: shutdown/poweroff/halt target job in queue"
fi

# Method 3: Check if shutdown/reboot targets are active or activating
if systemctl is-active --quiet shutdown.target 2>/dev/null || \
   systemctl is-active --quiet poweroff.target 2>/dev/null || \
   systemctl is-active --quiet halt.target 2>/dev/null; then
    is_system_shutdown=true
    log "Detected: shutdown/poweroff/halt target is active"
fi

if systemctl is-active --quiet reboot.target 2>/dev/null; then
    is_system_shutdown=true
    is_reboot=true
    log "Detected: reboot.target is active"
fi

# Method 4: Check for scheduled shutdown file
if [ -f /run/systemd/shutdown/scheduled ]; then
    is_system_shutdown=true
    if grep -q "reboot" /run/systemd/shutdown/scheduled 2>/dev/null; then
        is_reboot=true
        log "Detected: /run/systemd/shutdown/scheduled contains 'reboot'"
    else
        log "Detected: /run/systemd/shutdown/scheduled exists (shutdown)"
    fi
fi

# Method 5: Check runlevel (0=halt, 6=reboot)
runlevel_output=$(runlevel 2>/dev/null | awk '{print $2}')
if [ "$runlevel_output" = "0" ]; then
    is_system_shutdown=true
    log "Detected: runlevel 0 (halt)"
elif [ "$runlevel_output" = "6" ]; then
    is_system_shutdown=true
    is_reboot=true
    log "Detected: runlevel 6 (reboot)"
fi

# Method 6: Check /run/nologin (created during shutdown)
if [ -f /run/nologin ]; then
    is_system_shutdown=true
    log "Detected: /run/nologin exists (system shutting down)"
fi

# If not a system shutdown, exit without sending notification
if [ "$is_system_shutdown" = false ]; then
    log "Service stopped manually (not a system shutdown). No notification sent."
    log "=== Shutdown notification script completed (no action) ==="
    exit 0
fi

# Build the event type and message
if [ "$is_reboot" = true ]; then
    event_type="system_reboot"
    reason="The system is rebooting."
else
    event_type="system_shutdown"
    reason="The system is shutting down."
fi

hostname=$(hostname)
log "Event type: $event_type, Hostname: $hostname"

# Try to send notification via internal API endpoint
log "Sending notification to http://127.0.0.1:$PORT/api/internal/shutdown-event"

response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:$PORT/api/internal/shutdown-event" \
    -H "Content-Type: application/json" \
    -d "{\"event_type\": \"$event_type\", \"hostname\": \"$hostname\", \"reason\": \"$reason\"}" \
    --max-time 10 2>&1)

http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n -1)

log "Response HTTP code: $http_code"
log "Response body: $body"

if [ "$http_code" = "200" ]; then
    log "Notification sent successfully"
else
    log "WARNING: Notification may have failed (HTTP $http_code)"
fi

# Give the notification a moment to be sent
log "Waiting 3 seconds for notification delivery..."
sleep 3

log "=== Shutdown notification script completed ==="
exit 0
