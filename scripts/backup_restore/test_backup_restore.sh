#!/bin/bash
# ==========================================================
# ProxMenux - Backup/Restore Test Matrix (non-destructive)
# ==========================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/run_scheduled_backup.sh"
APPLY_ONBOOT="${SCRIPT_DIR}/apply_pending_restore.sh"
HOST_SCRIPT="${SCRIPT_DIR}/backup_host.sh"
LIB_SCRIPT="${SCRIPT_DIR}/lib_host_backup_common.sh"
SCHED_SCRIPT="${SCRIPT_DIR}/backup_scheduler.sh"

KEEP_TMP=0
if [[ "${1:-}" == "--keep-tmp" ]]; then
  KEEP_TMP=1
fi

TMP_ROOT="$(mktemp -d /tmp/proxmenux-brtest.XXXXXX)"
REPORT_FILE="/tmp/proxmenux-backup-restore-test-$(date +%Y%m%d_%H%M%S).log"

PASS=0
FAIL=0
SKIP=0

log() {
  echo "$*" | tee -a "$REPORT_FILE"
}

pass() {
  PASS=$((PASS + 1))
  log "[PASS] $*"
}

fail() {
  FAIL=$((FAIL + 1))
  log "[FAIL] $*"
}

skip() {
  SKIP=$((SKIP + 1))
  log "[SKIP] $*"
}

cleanup() {
  if [[ "$KEEP_TMP" -eq 0 ]]; then
    rm -rf "$TMP_ROOT"
  else
    log "[INFO] Temp root preserved: $TMP_ROOT"
  fi
}
trap cleanup EXIT

assert_file_contains() {
  local file="$1"
  local needle="$2"
  if [[ -f "$file" ]] && grep -q "$needle" "$file"; then
    return 0
  fi
  return 1
}

run_cmd_expect_ok() {
  local desc="$1"
  shift
  if "$@" >>"$REPORT_FILE" 2>&1; then
    pass "$desc"
    return 0
  fi
  fail "$desc"
  return 1
}

run_cmd_expect_fail() {
  local desc="$1"
  shift
  if "$@" >>"$REPORT_FILE" 2>&1; then
    fail "$desc"
    return 1
  fi
  pass "$desc"
  return 0
}

syntax_tests() {
  log "\n=== Syntax checks ==="
  run_cmd_expect_ok "bash -n backup_host.sh" bash -n "$HOST_SCRIPT"
  run_cmd_expect_ok "bash -n lib_host_backup_common.sh" bash -n "$LIB_SCRIPT"
  run_cmd_expect_ok "bash -n backup_scheduler.sh" bash -n "$SCHED_SCRIPT"
  run_cmd_expect_ok "bash -n run_scheduled_backup.sh" bash -n "$RUNNER"
  run_cmd_expect_ok "bash -n apply_pending_restore.sh" bash -n "$APPLY_ONBOOT"
}

scheduler_e2e_tests() {
  log "\n=== Scheduler E2E (sandbox) ==="
  if ! help mapfile >/dev/null 2>&1; then
    skip "Scheduler E2E skipped: current bash does not provide mapfile (requires bash >= 4)."
    return
  fi

  local jobs_dir="$TMP_ROOT/backup-jobs"
  local logs_dir="$TMP_ROOT/backup-jobs-logs"
  local lock_dir="$TMP_ROOT/locks"
  local archives_dir="$TMP_ROOT/archives"

  mkdir -p "$jobs_dir" "$logs_dir" "$lock_dir" "$archives_dir"

  cat > "$jobs_dir/t1.env" <<EOJ
JOB_ID=t1
BACKEND=local
PROFILE_MODE=custom
LOCAL_DEST_DIR=${archives_dir}
LOCAL_ARCHIVE_EXT=tar.gz
KEEP_LAST=2
KEEP_HOURLY=0
KEEP_DAILY=0
KEEP_WEEKLY=0
KEEP_MONTHLY=0
KEEP_YEARLY=0
EOJ

  cat > "$jobs_dir/t1.paths" <<EOP
/etc/hosts
/etc/resolv.conf
EOP

  local i
  for i in 1 2 3; do
    if PMX_BACKUP_JOBS_DIR="$jobs_dir" PMX_BACKUP_LOG_DIR="$logs_dir" PMX_BACKUP_LOCK_DIR="$lock_dir" \
      bash "$RUNNER" t1 >>"$REPORT_FILE" 2>&1; then
      :
    else
      fail "Runner execution #$i for t1"
      return
    fi
    sleep 1
  done

  local archive_count
  archive_count="$(find "$archives_dir" -maxdepth 1 -type f -name 't1-*.tar.gz' | wc -l | tr -d ' ')"
  if [[ "$archive_count" == "2" ]]; then
    pass "Retention KEEP_LAST=2 keeps exactly 2 archives"
  else
    fail "Retention expected 2 archives, got $archive_count"
  fi

  if assert_file_contains "$logs_dir/t1-last.status" "RESULT=ok"; then
    pass "t1-last.status reports RESULT=ok"
  else
    fail "t1-last.status does not report RESULT=ok"
  fi

  cat > "$jobs_dir/tbad.env" <<EOJ
JOB_ID=tbad
BACKEND=invalid
PROFILE_MODE=custom
KEEP_LAST=1
EOJ
  echo "/etc/hosts" > "$jobs_dir/tbad.paths"

  run_cmd_expect_fail "Invalid backend fails" \
    env PMX_BACKUP_JOBS_DIR="$jobs_dir" PMX_BACKUP_LOG_DIR="$logs_dir" PMX_BACKUP_LOCK_DIR="$lock_dir" \
    bash "$RUNNER" tbad

  if assert_file_contains "$logs_dir/tbad-last.status" "RESULT=failed"; then
    pass "tbad-last.status reports RESULT=failed"
  else
    fail "tbad-last.status does not report RESULT=failed"
  fi

  cat > "$jobs_dir/tempty.env" <<EOJ
JOB_ID=tempty
BACKEND=local
PROFILE_MODE=custom
LOCAL_DEST_DIR=${archives_dir}
LOCAL_ARCHIVE_EXT=tar.gz
KEEP_LAST=1
EOJ
  : > "$jobs_dir/tempty.paths"

  run_cmd_expect_fail "Empty paths fails" \
    env PMX_BACKUP_JOBS_DIR="$jobs_dir" PMX_BACKUP_LOG_DIR="$logs_dir" PMX_BACKUP_LOCK_DIR="$lock_dir" \
    bash "$RUNNER" tempty

  if assert_file_contains "$logs_dir/tempty-last.status" "RESULT=failed"; then
    pass "tempty-last.status reports RESULT=failed"
  else
    fail "tempty-last.status does not report RESULT=failed"
  fi
}

pending_restore_tests() {
  log "\n=== Pending restore E2E (sandbox) ==="
  local pending_base="$TMP_ROOT/restore-pending"
  local logs_dir="$TMP_ROOT/restore-logs"
  local target_root="$TMP_ROOT/target"
  local pre_backup_base="$TMP_ROOT/pre-restore"
  local recovery_base="$TMP_ROOT/recovery"

  mkdir -p "$pending_base/r1/rootfs/etc/pve" "$pending_base/r1/rootfs/etc/zfs" "$pending_base/r1/rootfs/etc" "$target_root/etc"

  echo "new-value" > "$pending_base/r1/rootfs/etc/test.conf"
  echo "cluster-data" > "$pending_base/r1/rootfs/etc/pve/cluster.cfg"
  echo "zfs-data" > "$pending_base/r1/rootfs/etc/zfs/zpool.cache"
  echo "old-value" > "$target_root/etc/test.conf"

  cat > "$pending_base/r1/apply-on-boot.list" <<EOL
etc/test.conf
etc/pve/cluster.cfg
etc/zfs/zpool.cache
EOL

  cat > "$pending_base/r1/plan.env" <<EOP
HB_RESTORE_INCLUDE_ZFS=0
EOP

  ln -sfn "$pending_base/r1" "$pending_base/current"

  if PMX_RESTORE_PENDING_BASE="$pending_base" PMX_RESTORE_LOG_DIR="$logs_dir" \
     PMX_RESTORE_DEST_PREFIX="$target_root" PMX_RESTORE_PRE_BACKUP_BASE="$pre_backup_base" \
     PMX_RESTORE_RECOVERY_BASE="$recovery_base" \
     bash "$APPLY_ONBOOT" >>"$REPORT_FILE" 2>&1; then
    pass "apply_pending_restore completes"
  else
    fail "apply_pending_restore completes"
    return
  fi

  if assert_file_contains "$target_root/etc/test.conf" "new-value"; then
    pass "Regular file restored into target prefix"
  else
    fail "Regular file was not restored"
  fi

  if [[ -e "$target_root/etc/pve/cluster.cfg" ]]; then
    fail "Cluster file should not be restored live"
  else
    pass "Cluster file skipped from live restore"
  fi

  if find "$recovery_base" -type f -name cluster.cfg 2>/dev/null | grep -q .; then
    pass "Cluster file extracted to recovery directory"
  else
    fail "Cluster file not found in recovery directory"
  fi

  if assert_file_contains "$pending_base/completed/r1/state" "completed"; then
    pass "Pending restore state marked completed"
  else
    fail "Pending restore state not marked completed"
  fi

  if [[ -e "$pending_base/current" ]]; then
    fail "current symlink should be removed"
  else
    pass "current symlink removed"
  fi
}

main() {
  log "ProxMenux backup/restore test matrix"
  log "Report: $REPORT_FILE"
  log "Temp root: $TMP_ROOT"

  syntax_tests
  scheduler_e2e_tests
  pending_restore_tests

  log "\n=== Summary ==="
  log "PASS=$PASS"
  log "FAIL=$FAIL"
  log "SKIP=$SKIP"

  if [[ "$FAIL" -eq 0 ]]; then
    log "RESULT=OK"
    exit 0
  else
    log "RESULT=FAILED"
    exit 1
  fi
}

main "$@"
