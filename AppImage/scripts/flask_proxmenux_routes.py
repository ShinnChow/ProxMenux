from flask import Blueprint, jsonify, request
import json
import os
import re

proxmenux_bp = Blueprint('proxmenux', __name__)

# Tool metadata: description, function name in bash script, and version
# version: current version of the optimization function
# function: the bash function name that implements this optimization
TOOL_METADATA = {
    'subscription_banner':  {'name': 'Subscription Banner Removal',           'function': 'remove_subscription_banner',   'version': '1.0'},
    'time_sync':            {'name': 'Time Synchronization',                  'function': 'configure_time_sync',          'version': '1.0'},
    'apt_languages':        {'name': 'APT Language Skip',                     'function': 'skip_apt_languages',           'version': '1.0'},
    'journald':             {'name': 'Journald Optimization',                 'function': 'optimize_journald',            'version': '1.1'},
    'logrotate':            {'name': 'Logrotate Optimization',                'function': 'optimize_logrotate',           'version': '1.1'},
    'system_limits':        {'name': 'System Limits Increase',                'function': 'increase_system_limits',       'version': '1.1'},
    # entropy removed — modern kernels 5.6+ have built-in entropy generation, haveged no longer needed
    'memory_settings':      {'name': 'Memory Settings Optimization',          'function': 'optimize_memory_settings',     'version': '1.1'},
    'kernel_panic':         {'name': 'Kernel Panic Configuration',            'function': 'configure_kernel_panic',       'version': '1.0'},
    'apt_ipv4':             {'name': 'APT IPv4 Force',                        'function': 'force_apt_ipv4',               'version': '1.0'},
    'kexec':                {'name': 'kexec for quick reboots',               'function': 'enable_kexec',                 'version': '1.0'},
    'network_optimization': {'name': 'Network Optimizations',                 'function': 'apply_network_optimizations',  'version': '1.0'},
    'bashrc_custom':        {'name': 'Bashrc Customization',                  'function': 'customize_bashrc',             'version': '1.0'},
    'figurine':             {'name': 'Figurine',                              'function': 'configure_figurine',           'version': '1.0'},
    'fastfetch':            {'name': 'Fastfetch',                             'function': 'configure_fastfetch',          'version': '1.0'},
    'log2ram':              {'name': 'Log2ram (SSD Protection)',               'function': 'configure_log2ram',            'version': '1.0'},
    'amd_fixes':            {'name': 'AMD CPU (Ryzen/EPYC) fixes',            'function': 'apply_amd_fixes',              'version': '1.0'},
    'persistent_network':   {'name': 'Setting persistent network interfaces', 'function': 'setup_persistent_network',     'version': '1.0'},
    'vfio_iommu':           {'name': 'VFIO/IOMMU Passthrough',                'function': 'enable_vfio_iommu',            'version': '1.0'},
    'lvm_repair':           {'name': 'LVM PV Headers Repair',                 'function': 'repair_lvm_headers',           'version': '1.0'},
    'repo_cleanup':         {'name': 'Repository Cleanup',                    'function': 'cleanup_repos',                'version': '1.0'},
    # ── Legacy / Deprecated entries ──
    # These optimizations were applied by previous ProxMenux versions but are
    # no longer needed or have been removed from the current scripts. We still
    # expose their source code for transparency with existing users.
    'entropy':              {'name': 'Entropy Generation (haveged)',           'function': 'configure_entropy',            'version': '1.0', 'deprecated': True},
}

# Backward-compatible description mapping (used by get_installed_tools)
TOOL_DESCRIPTIONS = {k: v['name'] for k, v in TOOL_METADATA.items()}

# Source code preserved for deprecated/removed optimization functions.
# When a function is removed from the active bash scripts (because it's
# no longer needed, e.g. obsoleted by kernel improvements), keep its code
# here so users who installed it in the past can still inspect what ran.
DEPRECATED_SOURCES = {
    'configure_entropy': {
        'script': 'customizable_post_install.sh (legacy)',
        'source': '''# ─────────────────────────────────────────────────────────────────
# NOTE: This optimization has been REMOVED from current ProxMenux versions.
# Modern Linux kernels (5.6+, shipped with Proxmox VE 7.x and 8.x) include
# built-in entropy generation via the Jitter RNG and CRNG, making haveged
# unnecessary. The function below is preserved here for transparency so
# users who applied it in the past can see exactly what was installed.
# New ProxMenux installations no longer include this optimization.
# ─────────────────────────────────────────────────────────────────

configure_entropy() {
    msg_info2 "$(translate "Configuring entropy generation to prevent slowdowns...")"

    # Install haveged
    msg_info "$(translate "Installing haveged...")"
    /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::='--force-confdef' install haveged > /dev/null 2>&1
    msg_ok "$(translate "haveged installed successfully")"

    # Configure haveged
    msg_info "$(translate "Configuring haveged...")"
    cat <<EOF > /etc/default/haveged
#   -w sets low entropy watermark (in bits)
DAEMON_ARGS="-w 1024"
EOF

    # Reload systemd daemon
    systemctl daemon-reload > /dev/null 2>&1

    # Enable haveged service
    systemctl enable haveged > /dev/null 2>&1
    msg_ok "$(translate "haveged service enabled successfully")"

    register_tool "entropy" true
    msg_success "$(translate "Entropy generation configuration completed")"
}
''',
    },
}

# Scripts to search for function source code (in order of preference)
_SCRIPT_PATHS = [
    '/usr/local/share/proxmenux/scripts/post_install/customizable_post_install.sh',
    '/usr/local/share/proxmenux/scripts/post_install/auto_post_install.sh',
]


def _extract_bash_function(function_name: str) -> dict:
    """Extract a bash function's source code.

    Checks DEPRECATED_SOURCES first (for functions removed from active scripts),
    then searches the live bash scripts for `function_name() {` and captures
    everything until the matching closing `}`, respecting brace nesting.

    Returns {'source': str, 'script': str, 'line_start': int, 'line_end': int}
    or {'source': '', 'error': '...'} on failure.
    """
    # Check preserved deprecated source code first
    if function_name in DEPRECATED_SOURCES:
        entry = DEPRECATED_SOURCES[function_name]
        source = entry['source']
        return {
            'source': source,
            'script': entry['script'],
            'line_start': 1,
            'line_end': len(source.split('\n')),
        }

    for script_path in _SCRIPT_PATHS:
        if not os.path.isfile(script_path):
            continue
        try:
            with open(script_path, 'r') as f:
                lines = f.readlines()

            # Find function start: "function_name() {" or "function_name () {"
            pattern = re.compile(rf'^{re.escape(function_name)}\s*\(\)\s*\{{')
            start_idx = None
            for i, line in enumerate(lines):
                if pattern.match(line):
                    start_idx = i
                    break

            if start_idx is None:
                continue  # Try next script

            # Capture until the closing } at indent level 0
            brace_depth = 0
            end_idx = start_idx
            for i in range(start_idx, len(lines)):
                brace_depth += lines[i].count('{') - lines[i].count('}')
                if brace_depth <= 0:
                    end_idx = i
                    break

            source = ''.join(lines[start_idx:end_idx + 1])
            script_name = os.path.basename(script_path)

            return {
                'source': source,
                'script': script_name,
                'line_start': start_idx + 1,
                'line_end': end_idx + 1,
            }
        except Exception:
            continue

    return {'source': '', 'error': 'Function not found in available scripts'}

@proxmenux_bp.route('/api/proxmenux/update-status', methods=['GET'])
def get_update_status():
    """Get ProxMenux update availability status from config.json"""
    config_path = '/usr/local/share/proxmenux/config.json'
    
    try:
        if not os.path.exists(config_path):
            return jsonify({
                'success': True,
                'update_available': {
                    'stable': False,
                    'stable_version': '',
                    'beta': False,
                    'beta_version': ''
                }
            })
        
        with open(config_path, 'r') as f:
            config = json.load(f)
        
        update_status = config.get('update_available', {
            'stable': False,
            'stable_version': '',
            'beta': False,
            'beta_version': ''
        })
        
        return jsonify({
            'success': True,
            'update_available': update_status
        })
    
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500


@proxmenux_bp.route('/api/proxmenux/installed-tools', methods=['GET'])
def get_installed_tools():
    """Get list of installed ProxMenux tools/optimizations"""
    installed_tools_path = '/usr/local/share/proxmenux/installed_tools.json'
    
    try:
        if not os.path.exists(installed_tools_path):
            return jsonify({
                'success': True,
                'installed_tools': [],
                'message': 'No ProxMenux optimizations installed yet'
            })
        
        with open(installed_tools_path, 'r') as f:
            data = json.load(f)
        
        # Convert to list format with descriptions and version
        tools = []
        for tool_key, enabled in data.items():
            if enabled:  # Only include enabled tools
                meta = TOOL_METADATA.get(tool_key, {})
                tools.append({
                    'key': tool_key,
                    'name': meta.get('name', tool_key.replace('_', ' ').title()),
                    'enabled': enabled,
                    'version': meta.get('version', '1.0'),
                    'has_source': bool(meta.get('function')),
                    'deprecated': bool(meta.get('deprecated', False)),
                })
        
        # Sort alphabetically by name
        tools.sort(key=lambda x: x['name'])
        
        return jsonify({
            'success': True,
            'installed_tools': tools,
            'total_count': len(tools)
        })
    
    except json.JSONDecodeError:
        return jsonify({
            'success': False,
            'error': 'Invalid JSON format in installed_tools.json'
        }), 500
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500


@proxmenux_bp.route('/api/proxmenux/tool-source/<tool_key>', methods=['GET'])
def get_tool_source(tool_key):
    """Get the bash source code of a specific optimization function.

    Returns the function body extracted from the post-install scripts,
    so users can see exactly what code was executed on their server.
    """
    try:
        meta = TOOL_METADATA.get(tool_key)
        if not meta:
            return jsonify({
                'success': False,
                'error': f'Unknown tool: {tool_key}'
            }), 404

        func_name = meta.get('function')
        if not func_name:
            return jsonify({
                'success': False,
                'error': f'No function mapping for {tool_key}'
            }), 404

        result = _extract_bash_function(func_name)

        if not result.get('source'):
            return jsonify({
                'success': False,
                'error': result.get('error', 'Source code not available'),
                'tool': tool_key,
                'function': func_name,
            }), 404

        return jsonify({
            'success': True,
            'tool': tool_key,
            'name': meta['name'],
            'version': meta.get('version', '1.0'),
            'deprecated': bool(meta.get('deprecated', False)),
            'function': func_name,
            'source': result['source'],
            'script': result['script'],
            'line_start': result['line_start'],
            'line_end': result['line_end'],
        })

    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500
