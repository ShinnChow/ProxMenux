"""
Centralized Startup Grace Period Management

This module provides a single source of truth for startup grace period logic.
During system boot, various transient issues occur (high latency, storage not ready,
QMP timeouts, etc.) that shouldn't trigger notifications or critical alerts.

Grace Periods:
- VM/CT aggregation: 3 minutes - Aggregate multiple VM/CT starts into one notification
- Health suppression: 5 minutes - Suppress transient health warnings/errors
- Shutdown suppression: 2 minutes - Suppress VM/CT stops during system shutdown

Categories suppressed during startup:
- storage: NFS/CIFS mounts may take time to become available
- vms: VMs may have QMP timeouts or startup delays
- network: Latency spikes during boot are normal
- services: PVE services may take time to fully initialize
"""

import time
import threading
from typing import Set, List, Tuple, Optional

# ─── Configuration ───────────────────────────────────────────────────────────

# Grace period durations (seconds)
STARTUP_VM_GRACE_SECONDS = 180      # 3 minutes for VM/CT start aggregation
STARTUP_HEALTH_GRACE_SECONDS = 300  # 5 minutes for health warning suppression
SHUTDOWN_GRACE_SECONDS = 120        # 2 minutes for VM/CT stop suppression

# Maximum system uptime to consider this a real server boot (not just service restart)
# If system uptime > this value when service starts, skip startup notification
MAX_BOOT_UPTIME_SECONDS = 600       # 10 minutes - if system was up longer, it's a service restart


def _get_system_uptime() -> float:
    """
    Get actual system uptime in seconds from /proc/uptime.
    Returns 0 if unable to read (will default to treating as new boot).
    """
    try:
        with open('/proc/uptime', 'r') as f:
            return float(f.readline().split()[0])
    except Exception:
        return 0

# Categories to suppress during startup grace period
# These categories typically have transient issues during boot
STARTUP_GRACE_CATEGORIES: Set[str] = {
    'storage',   # NFS/CIFS mounts may take time
    'vms',       # VMs may have QMP timeouts
    'network',   # Latency spikes during boot
    'services',  # PVE services initialization
}


# ─── Singleton State ─────────────────────────────────────────────────────────

class _StartupGraceState:
    """
    Thread-safe singleton managing all startup/shutdown grace period state.
    
    Initialized when the module loads (service start), which serves as the
    reference point for determining if we're still in the startup period.
    """
    
    _instance: Optional['_StartupGraceState'] = None
    _init_lock = threading.Lock()
    
    def __new__(cls) -> '_StartupGraceState':
        if cls._instance is None:
            with cls._init_lock:
                if cls._instance is None:
                    cls._instance = super().__new__(cls)
                    cls._instance._initialized = False
        return cls._instance
    
    def __init__(self):
        if self._initialized:
            return
        
        self._lock = threading.Lock()
        
        # Startup time = when service started (module load time)
        self._startup_time: float = time.time()
        
        # Check if this is a REAL system boot or just a service restart
        # by comparing system uptime to our threshold
        system_uptime = _get_system_uptime()
        self._is_real_boot: bool = system_uptime < MAX_BOOT_UPTIME_SECONDS
        
        # Shutdown tracking
        self._shutdown_time: float = 0
        
        # VM/CT aggregation during startup
        self._startup_vms: List[Tuple[str, str, str]] = []  # [(vmid, vmname, 'vm'|'ct'), ...]
        self._startup_aggregated: bool = False
        
        self._initialized = True
    
    # ─── Startup Period Checks ───────────────────────────────────────────────
    
    def is_startup_vm_period(self) -> bool:
        """
        Check if we're within the VM/CT start aggregation period (3 min).
        
        During this period, individual VM/CT start notifications are collected
        and later sent as a single aggregated notification.
        """
        with self._lock:
            return (time.time() - self._startup_time) < STARTUP_VM_GRACE_SECONDS
    
    def is_startup_health_grace(self) -> bool:
        """
        Check if we're within the health suppression period (5 min).
        
        During this period:
        - Transient health warnings (latency, storage, etc.) are suppressed
        - CRITICAL/WARNING may be downgraded to INFO for certain categories
        - Health degradation notifications are skipped for grace categories
        """
        with self._lock:
            return (time.time() - self._startup_time) < STARTUP_HEALTH_GRACE_SECONDS
    
    def should_suppress_category(self, category: str) -> bool:
        """
        Check if notifications for a category should be suppressed.
        
        Args:
            category: Health category name (e.g., 'network', 'storage', 'vms')
        
        Returns:
            True if we're in grace period AND category is in STARTUP_GRACE_CATEGORIES
        """
        if category.lower() in STARTUP_GRACE_CATEGORIES:
            return self.is_startup_health_grace()
        return False
    
    def is_real_system_boot(self) -> bool:
        """
        Check if the service started during a real system boot.
        
        Returns False if the system was already running for more than 10 minutes
        when the service started (indicates a service restart, not a system boot).
        
        This prevents sending "System startup completed" notifications when
        just restarting the ProxMenux Monitor service.
        """
        with self._lock:
            return self._is_real_boot
    
    def get_startup_elapsed(self) -> float:
        """Get seconds elapsed since service startup."""
        with self._lock:
            return time.time() - self._startup_time
    
    # ─── Shutdown Tracking ───────────────────────────────────────────────────
    
    def mark_shutdown(self):
        """
        Called when system_shutdown or system_reboot is detected.
        
        After this, VM/CT stop notifications will be suppressed for the
        shutdown grace period (expected stops during system shutdown).
        """
        with self._lock:
            self._shutdown_time = time.time()
    
    def is_host_shutting_down(self) -> bool:
        """
        Check if we're within the shutdown grace period.
        
        During this period, VM/CT stop events are expected and should not
        generate notifications.
        """
        with self._lock:
            if self._shutdown_time == 0:
                return False
            return (time.time() - self._shutdown_time) < SHUTDOWN_GRACE_SECONDS
    
    # ─── VM/CT Start Aggregation ─────────────────────────────────────────────
    
    def add_startup_vm(self, vmid: str, vmname: str, vm_type: str):
        """
        Record a VM/CT start during startup period for later aggregation.
        
        Args:
            vmid: VM/CT ID
            vmname: VM/CT name
            vm_type: 'vm' or 'ct'
        """
        with self._lock:
            self._startup_vms.append((vmid, vmname, vm_type))
    
    def get_and_clear_startup_vms(self) -> List[Tuple[str, str, str]]:
        """
        Get all recorded startup VMs and clear the list.
        
        Should be called once after the VM aggregation grace period ends
        to get all VMs that started during boot for a single notification.
        
        Returns:
            List of (vmid, vmname, vm_type) tuples
        """
        with self._lock:
            vms = self._startup_vms.copy()
            self._startup_vms = []
            self._startup_aggregated = True
            return vms
    
    def has_startup_vms(self) -> bool:
        """Check if there are any startup VMs recorded."""
        with self._lock:
            return len(self._startup_vms) > 0
    
    def was_startup_aggregated(self) -> bool:
        """Check if startup aggregation has already been processed."""
        with self._lock:
            return self._startup_aggregated
    
    def mark_startup_aggregated(self) -> None:
        """Mark startup aggregation as completed without returning VMs."""
        with self._lock:
            self._startup_aggregated = True


# ─── Module-level convenience functions ──────────────────────────────────────

# Global singleton instance
_state = _StartupGraceState()

def is_startup_vm_period() -> bool:
    """Check if we're within the VM/CT start aggregation period (3 min)."""
    return _state.is_startup_vm_period()

def is_startup_health_grace() -> bool:
    """Check if we're within the health suppression period (5 min)."""
    return _state.is_startup_health_grace()

def should_suppress_category(category: str) -> bool:
    """Check if notifications for a category should be suppressed during startup."""
    return _state.should_suppress_category(category)

def get_startup_elapsed() -> float:
    """Get seconds elapsed since service startup."""
    return _state.get_startup_elapsed()

def mark_shutdown():
    """Mark that system shutdown/reboot has been detected."""
    _state.mark_shutdown()

def is_host_shutting_down() -> bool:
    """Check if we're within the shutdown grace period."""
    return _state.is_host_shutting_down()

def add_startup_vm(vmid: str, vmname: str, vm_type: str):
    """Record a VM/CT start during startup period for aggregation."""
    _state.add_startup_vm(vmid, vmname, vm_type)

def get_and_clear_startup_vms() -> List[Tuple[str, str, str]]:
    """Get all recorded startup VMs and clear the list."""
    return _state.get_and_clear_startup_vms()

def has_startup_vms() -> bool:
    """Check if there are any startup VMs recorded."""
    return _state.has_startup_vms()

def was_startup_aggregated() -> bool:
    """Check if startup aggregation has already been processed."""
    return _state.was_startup_aggregated()

def mark_startup_aggregated() -> None:
    """Mark startup aggregation as completed without processing VMs.
    
    Use this when skipping startup notification (e.g., service restart
    instead of real system boot) to prevent future checks.
    """
    _state.mark_startup_aggregated()

def is_real_system_boot() -> bool:
    """
    Check if this is a real system boot (not just a service restart).
    
    Returns True if the system uptime was less than 10 minutes when the
    service started. Returns False if the system was already running
    longer (indicates the service was restarted, not the whole system).
    
    Use this to prevent sending "System startup completed" notifications
    when just restarting the ProxMenux Monitor service.
    """
    return _state.is_real_system_boot()


# ─── Startup Report Collection ───────────────────────────────────────────────

def collect_startup_report() -> dict:
    """
    Collect comprehensive startup report data.
    
    Called at the end of the grace period to generate a complete
    startup report including:
    - VMs/CTs that started successfully
    - VMs/CTs that failed to start
    - Service status
    - Storage status
    - Journal errors during boot (for AI enrichment)
    
    Returns:
        Dictionary with startup report data
    """
    import subprocess
    
    report = {
        # VMs/CTs
        'vms_started': [],
        'cts_started': [],
        'vms_failed': [],
        'cts_failed': [],
        
        # System status
        'services_ok': True,
        'services_failed': [],
        'storage_ok': True,
        'storage_unavailable': [],
        
        # Health summary
        'health_status': 'OK',
        'health_issues': [],
        
        # For AI enrichment
        '_journal_context': '',
        '_startup_errors': [],
        
        # Metadata
        'startup_duration_seconds': get_startup_elapsed(),
        'timestamp': int(time.time()),
    }
    
    # Get VMs/CTs that started during boot
    startup_vms = get_and_clear_startup_vms()
    for vmid, vmname, vm_type in startup_vms:
        if vm_type == 'vm':
            report['vms_started'].append({'vmid': vmid, 'name': vmname})
        else:
            report['cts_started'].append({'vmid': vmid, 'name': vmname})
    
    # Try to get health status from health_monitor
    try:
        import health_monitor
        health_data = health_monitor.get_detailed_status()
        
        if health_data:
            report['health_status'] = health_data.get('overall_status', 'UNKNOWN')
            
            # Check storage
            storage_cat = health_data.get('categories', {}).get('storage', {})
            if storage_cat.get('status') in ['CRITICAL', 'WARNING']:
                report['storage_ok'] = False
                for check in storage_cat.get('checks', []):
                    if check.get('status') in ['CRITICAL', 'WARNING', 'error']:
                        report['storage_unavailable'].append({
                            'name': check.get('name', 'unknown'),
                            'reason': check.get('reason', check.get('message', ''))
                        })
            
            # Check services
            services_cat = health_data.get('categories', {}).get('services', {})
            if services_cat.get('status') in ['CRITICAL', 'WARNING']:
                report['services_ok'] = False
                for check in services_cat.get('checks', []):
                    if check.get('status') in ['CRITICAL', 'WARNING', 'error']:
                        report['services_failed'].append({
                            'name': check.get('name', 'unknown'),
                            'reason': check.get('reason', check.get('message', ''))
                        })
            
            # Check VMs category for failed VMs
            vms_cat = health_data.get('categories', {}).get('vms', {})
            for check in vms_cat.get('checks', []):
                if check.get('status') in ['CRITICAL', 'WARNING', 'error']:
                    # Determine if VM or CT based on name/type
                    check_name = check.get('name', '')
                    check_reason = check.get('reason', check.get('message', ''))
                    if 'error al iniciar' in check_reason.lower() or 'failed to start' in check_reason.lower():
                        if 'CT' in check_name or 'Container' in check_name:
                            report['cts_failed'].append({
                                'name': check_name,
                                'reason': check_reason
                            })
                        else:
                            report['vms_failed'].append({
                                'name': check_name,
                                'reason': check_reason
                            })
            
            # Collect all health issues for summary
            for cat_name, cat_data in health_data.get('categories', {}).items():
                if cat_data.get('status') in ['CRITICAL', 'WARNING']:
                    report['health_issues'].append({
                        'category': cat_name,
                        'status': cat_data.get('status'),
                        'reason': cat_data.get('reason', '')
                    })
    except Exception as e:
        report['_startup_errors'].append(f"Error getting health data: {e}")
    
    # Get journal errors during startup (for AI enrichment)
    try:
        boot_time = int(_state._startup_time)
        result = subprocess.run(
            ['journalctl', '-p', 'err', '--since', f'@{boot_time}', '--no-pager', '-n', '50'],
            capture_output=True,
            text=True,
            timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            report['_journal_context'] = result.stdout.strip()
    except Exception as e:
        report['_startup_errors'].append(f"Error getting journal: {e}")
    
    return report


def format_startup_summary(report: dict) -> str:
    """
    Format a human-readable startup summary from report data.
    
    Args:
        report: Dictionary from collect_startup_report()
    
    Returns:
        Formatted summary string
    """
    lines = []
    
    # Count totals
    vms_ok = len(report.get('vms_started', []))
    cts_ok = len(report.get('cts_started', []))
    vms_fail = len(report.get('vms_failed', []))
    cts_fail = len(report.get('cts_failed', []))
    
    total_ok = vms_ok + cts_ok
    total_fail = vms_fail + cts_fail
    
    # Determine overall status
    has_issues = (
        total_fail > 0 or
        not report.get('services_ok', True) or
        not report.get('storage_ok', True) or
        report.get('health_status') in ['CRITICAL', 'WARNING']
    )
    
    # Header
    if has_issues:
        issue_count = total_fail + len(report.get('services_failed', [])) + len(report.get('storage_unavailable', []))
        lines.append(f"System startup - {issue_count} issue(s) detected")
    else:
        lines.append("System startup completed")
        lines.append("All systems operational.")
    
    # VMs/CTs started
    if total_ok > 0:
        parts = []
        if vms_ok > 0:
            parts.append(f"{vms_ok} VM{'s' if vms_ok > 1 else ''}")
        if cts_ok > 0:
            parts.append(f"{cts_ok} CT{'s' if cts_ok > 1 else ''}")
        
        # List names
        names = []
        for vm in report.get('vms_started', []):
            names.append(f"{vm['name']} ({vm['vmid']})")
        for ct in report.get('cts_started', []):
            names.append(f"{ct['name']} ({ct['vmid']})")
        
        line = f"{' and '.join(parts)} started"
        if names and len(names) <= 5:
            line += f": {', '.join(names)}"
        elif names:
            line += f": {', '.join(names[:3])}... (+{len(names)-3} more)"
        lines.append(line)
    
    # Failed VMs/CTs
    if total_fail > 0:
        for vm in report.get('vms_failed', []):
            lines.append(f"VM failed: {vm['name']} - {vm.get('reason', 'unknown error')}")
        for ct in report.get('cts_failed', []):
            lines.append(f"CT failed: {ct['name']} - {ct.get('reason', 'unknown error')}")
    
    # Storage issues
    if not report.get('storage_ok', True):
        unavailable = report.get('storage_unavailable', [])
        if unavailable:
            names = [s['name'] for s in unavailable]
            lines.append(f"Storage: {len(unavailable)} unavailable ({', '.join(names[:3])})")
    
    # Service issues
    if not report.get('services_ok', True):
        failed = report.get('services_failed', [])
        if failed:
            names = [s['name'] for s in failed]
            lines.append(f"Services: {len(failed)} failed ({', '.join(names[:3])})")
    
    return '\n'.join(lines)


# ─── For backwards compatibility ─────────────────────────────────────────────

# Expose constants for external use
GRACE_CATEGORIES = STARTUP_GRACE_CATEGORIES
