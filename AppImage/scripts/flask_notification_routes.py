"""
Flask routes for notification service configuration and management.
Blueprint pattern matching flask_health_routes.py / flask_security_routes.py.
"""

import hmac
import time
import json
import hashlib
from pathlib import Path
from collections import deque
from flask import Blueprint, jsonify, request
from notification_manager import notification_manager


# ─── Webhook Hardening Helpers ───────────────────────────────────

class WebhookRateLimiter:
    """Simple sliding-window rate limiter for the webhook endpoint."""
    
    def __init__(self, max_requests: int = 60, window_seconds: int = 60):
        self._max = max_requests
        self._window = window_seconds
        self._timestamps: deque = deque()
    
    def allow(self) -> bool:
        now = time.time()
        # Prune entries outside the window
        while self._timestamps and now - self._timestamps[0] > self._window:
            self._timestamps.popleft()
        if len(self._timestamps) >= self._max:
            return False
        self._timestamps.append(now)
        return True


class ReplayCache:
    """Bounded in-memory cache of recently seen request signatures (60s TTL)."""
    
    _MAX_SIZE = 2000  # Hard cap to prevent memory growth
    
    def __init__(self, ttl: int = 60):
        self._ttl = ttl
        self._seen: dict = {}  # signature -> timestamp
    
    def check_and_record(self, signature: str) -> bool:
        """Return True if this signature was already seen (replay). Records it otherwise."""
        now = time.time()
        # Periodic cleanup
        if len(self._seen) > self._MAX_SIZE // 2:
            cutoff = now - self._ttl
            self._seen = {k: v for k, v in self._seen.items() if v > cutoff}
        if signature in self._seen and now - self._seen[signature] < self._ttl:
            return True  # Replay detected
        self._seen[signature] = now
        return False


# Module-level singletons (one per process)
_webhook_limiter = WebhookRateLimiter(max_requests=60, window_seconds=60)
_replay_cache = ReplayCache(ttl=60)

# Timestamp validation window (seconds)
_TIMESTAMP_MAX_DRIFT = 60

notification_bp = Blueprint('notifications', __name__)


@notification_bp.route('/api/notifications/settings', methods=['GET'])
def get_notification_settings():
    """Get all notification settings for the UI."""
    try:
        settings = notification_manager.get_settings()
        return jsonify(settings)
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@notification_bp.route('/api/notifications/settings', methods=['POST'])
def save_notification_settings():
    """Save notification settings from the UI."""
    try:
        payload = request.get_json()
        if not payload:
            return jsonify({'error': 'No data provided'}), 400
        
        result = notification_manager.save_settings(payload)
        return jsonify(result)
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@notification_bp.route('/api/notifications/test', methods=['POST'])
def test_notification():
    """Send a test notification to one or all channels."""
    try:
        data = request.get_json() or {}
        channel = data.get('channel', 'all')
        
        result = notification_manager.test_channel(channel)
        return jsonify(result)
    except Exception as e:
        return jsonify({'error': str(e)}), 500


def load_verified_models():
    """Load verified models from config file.
    
    Checks multiple paths:
    1. Same directory as script (AppImage: /usr/bin/config/)
    2. Parent directory config folder (dev: AppImage/config/)
    """
    try:
        # Try AppImage path first (scripts and config both in /usr/bin/)
        script_dir = Path(__file__).parent
        config_path = script_dir / 'config' / 'verified_ai_models.json'
        
        if not config_path.exists():
            # Try development path (AppImage/scripts/ -> AppImage/config/)
            config_path = script_dir.parent / 'config' / 'verified_ai_models.json'
        
        if config_path.exists():
            with open(config_path, 'r') as f:
                return json.load(f)
        else:
            print(f"[flask_notification_routes] Config not found at {config_path}")
    except Exception as e:
        print(f"[flask_notification_routes] Failed to load verified models: {e}")
    return {}


@notification_bp.route('/api/notifications/provider-models', methods=['POST'])
def get_provider_models():
    """Fetch available models from AI provider, filtered by verified models list.
    
    Only returns models that:
    1. Are available from the provider's API
    2. Are in our verified_ai_models.json list (tested to work)
    
    Request body:
        {
            "provider": "gemini|groq|openai|openrouter|ollama|anthropic",
            "api_key": "your-api-key",  // Not needed for ollama
            "ollama_url": "http://localhost:11434",  // Only for ollama
            "openai_base_url": "https://custom.endpoint/v1"  // Optional for openai
        }
    
    Returns:
        {
            "success": true/false,
            "models": ["model1", "model2", ...],
            "recommended": "recommended-model",
            "message": "status message"
        }
    """
    try:
        data = request.get_json() or {}
        provider = data.get('provider', '')
        api_key = data.get('api_key', '')
        ollama_url = data.get('ollama_url', 'http://localhost:11434')
        openai_base_url = data.get('openai_base_url', '')
        
        if not provider:
            return jsonify({'success': False, 'models': [], 'message': 'Provider not specified'})
        
        # Load verified models config
        verified_config = load_verified_models()
        provider_config = verified_config.get(provider, {})
        verified_models = set(provider_config.get('models', []))
        recommended = provider_config.get('recommended', '')
        
        # Handle Ollama separately (local, no filtering)
        if provider == 'ollama':
            import urllib.request
            import urllib.error
            
            url = f"{ollama_url.rstrip('/')}/api/tags"
            req = urllib.request.Request(url, method='GET')
            req.add_header('User-Agent', 'ProxMenux-Monitor/1.1')
            
            with urllib.request.urlopen(req, timeout=10) as resp:
                result = json.loads(resp.read().decode('utf-8'))
                models = [m.get('name', '') for m in result.get('models', []) if m.get('name')]
                models = sorted(models)
                return jsonify({
                    'success': True,
                    'models': models,
                    'recommended': models[0] if models else '',
                    'message': f'Found {len(models)} local models'
                })
        
        # Handle Anthropic - no models list API, return verified models directly
        if provider == 'anthropic':
            models = list(verified_models) if verified_models else [
                'claude-3-5-haiku-latest',
                'claude-3-5-sonnet-latest',
                'claude-3-opus-latest',
            ]
            return jsonify({
                'success': True,
                'models': sorted(models),
                'recommended': recommended or models[0],
                'message': f'{len(models)} verified models'
            })
        
        # For other providers, fetch from API and filter by verified list
        if not api_key:
            return jsonify({'success': False, 'models': [], 'message': 'API key required'})
        
        from ai_providers import get_provider
        ai_provider = get_provider(
            provider, 
            api_key=api_key, 
            model='', 
            base_url=openai_base_url if provider == 'openai' else None
        )
        
        if not ai_provider:
            return jsonify({'success': False, 'models': [], 'message': f'Unknown provider: {provider}'})
        
        # Get all models from provider API
        api_models = ai_provider.list_models()

        # OpenAI with a custom base URL means an OpenAI-compatible endpoint
        # (LiteLLM, MLX, LM Studio, vLLM, LocalAI, Ollama-proxy...). The
        # verified_ai_models.json list only contains official OpenAI IDs
        # (gpt-4o-mini etc.), so intersecting against it would strip every
        # model the user actually serves. Treat the custom-endpoint case
        # like Ollama: return whatever the endpoint advertises, no filter.
        is_openai_compat = (provider == 'openai' and bool(openai_base_url))

        if not api_models:
            # API failed, fall back to verified list only (but not for
            # custom endpoints — we don't know what the endpoint serves,
            # so "gpt-4o-mini" as a fallback would be misleading).
            if verified_models and not is_openai_compat:
                models = sorted(verified_models)
                return jsonify({
                    'success': True,
                    'models': models,
                    'recommended': recommended or models[0],
                    'message': f'{len(models)} verified models (API unavailable)'
                })
            return jsonify({
                'success': False,
                'models': [],
                'message': 'Could not retrieve models. Check your API key and endpoint URL.'
            })

        if is_openai_compat:
            # Custom OpenAI-compatible endpoint: surface every model the
            # endpoint reports. No verified-list intersection.
            models = sorted(api_models)
            return jsonify({
                'success': True,
                'models': models,
                'recommended': models[0] if models else '',
                'message': f'Found {len(models)} models on custom endpoint'
            })

        # Filter: only models that are BOTH in API and verified list
        if verified_models:
            api_models_set = set(api_models)
            filtered_models = [m for m in verified_models if m in api_models_set]

            if not filtered_models:
                # No intersection - maybe verified list is outdated
                # Return verified list anyway (will fail on use if truly unavailable)
                filtered_models = list(verified_models)

            # Sort with recommended first
            def sort_key(m):
                if m == recommended:
                    return (0, m)
                return (1, m)

            models = sorted(filtered_models, key=sort_key)
        else:
            # No verified list for this provider, return all from API
            models = sorted(api_models)
        
        return jsonify({
            'success': True,
            'models': models,
            'recommended': recommended if recommended in models else (models[0] if models else ''),
            'message': f'{len(models)} verified models available'
        })
        
    except Exception as e:
        return jsonify({
            'success': False,
            'models': [],
            'message': f'Error: {str(e)}'
        })


@notification_bp.route('/api/notifications/test-ai', methods=['POST'])
def test_ai_connection():
    """Test AI provider connection and configuration.
    
    Request body:
        {
            "provider": "groq" | "openai" | "anthropic" | "gemini" | "ollama" | "openrouter",
            "api_key": "...",
            "model": "..." (optional),
            "ollama_url": "http://localhost:11434" (optional, for ollama)
        }
    
    Returns:
        {
            "success": true/false,
            "message": "Connection successful" or error message,
            "model": "model used for test"
        }
    """
    try:
        data = request.get_json() or {}
        
        provider = data.get('provider', 'groq')
        api_key = data.get('api_key', '')
        model = data.get('model', '')
        ollama_url = data.get('ollama_url', 'http://localhost:11434')
        openai_base_url = data.get('openai_base_url', '')
        
        # Validate required fields
        if provider != 'ollama' and not api_key:
            return jsonify({
                'success': False,
                'message': 'API key is required',
                'model': ''
            }), 400
        
        if provider == 'ollama' and not ollama_url:
            return jsonify({
                'success': False,
                'message': 'Ollama URL is required',
                'model': ''
            }), 400
        
        # Import and use the AI providers module
        import sys
        import os
        script_dir = os.path.dirname(os.path.abspath(__file__))
        if script_dir not in sys.path:
            sys.path.insert(0, script_dir)
        
        from ai_providers import get_provider, AIProviderError
        
        # Determine base_url based on provider
        if provider == 'ollama':
            base_url = ollama_url
        elif provider == 'openai':
            base_url = openai_base_url  # Empty string means use default OpenAI API
        else:
            base_url = ''
        
        try:
            ai_provider = get_provider(
                provider,
                api_key=api_key,
                model=model,
                base_url=base_url
            )
            
            result = ai_provider.test_connection()
            return jsonify(result)
            
        except AIProviderError as e:
            return jsonify({
                'success': False,
                'message': str(e),
                'model': model
            }), 400
            
    except Exception as e:
        return jsonify({
            'success': False,
            'message': f'Unexpected error: {str(e)}',
            'model': ''
        }), 500


@notification_bp.route('/api/notifications/status', methods=['GET'])
def get_notification_status():
    """Get notification service status."""
    try:
        status = notification_manager.get_status()
        return jsonify(status)
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@notification_bp.route('/api/notifications/history', methods=['GET'])
def get_notification_history():
    """Get notification history with optional filters."""
    try:
        limit = request.args.get('limit', 100, type=int)
        offset = request.args.get('offset', 0, type=int)
        severity = request.args.get('severity', '')
        channel = request.args.get('channel', '')
        
        result = notification_manager.get_history(limit, offset, severity, channel)
        return jsonify(result)
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@notification_bp.route('/api/notifications/history', methods=['DELETE'])
def clear_notification_history():
    """Clear all notification history."""
    try:
        result = notification_manager.clear_history()
        return jsonify(result)
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@notification_bp.route('/api/notifications/send', methods=['POST'])
def send_notification():
    """Send a notification via API (for testing or external triggers)."""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'No data provided'}), 400
        
        result = notification_manager.send_notification(
            event_type=data.get('event_type', 'custom'),
            severity=data.get('severity', 'INFO'),
            title=data.get('title', ''),
            message=data.get('message', ''),
            data=data.get('data', {}),
            source='api'
        )
        return jsonify(result)
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ── PVE config constants ──
_PVE_ENDPOINT_ID = 'proxmenux-webhook'
_PVE_MATCHER_ID = 'proxmenux-default'
_PVE_WEBHOOK_URL = 'http://127.0.0.1:8008/api/notifications/webhook'
_PVE_NOTIFICATIONS_CFG = '/etc/pve/notifications.cfg'
_PVE_PRIV_CFG = '/etc/pve/priv/notifications.cfg'
_PVE_OUR_HEADERS = {
    f'webhook: {_PVE_ENDPOINT_ID}',
    f'matcher: {_PVE_MATCHER_ID}',
}


def _pve_read_file(path):
    """Read file, return (content, error). Content is '' if missing."""
    try:
        with open(path, 'r') as f:
            return f.read(), None
    except FileNotFoundError:
        return '', None
    except PermissionError:
        return None, f'Permission denied reading {path}'
    except Exception as e:
        return None, str(e)


def _pve_backup_file(path):
    """Create timestamped backup if file exists. Never fails fatally."""
    import os, shutil
    from datetime import datetime
    try:
        if os.path.exists(path):
            ts = datetime.now().strftime('%Y%m%d_%H%M%S')
            backup = f"{path}.proxmenux_backup_{ts}"
            shutil.copy2(path, backup)
    except Exception:
        pass


def _pve_remove_our_blocks(text, headers_to_remove):
    """Remove only blocks whose header line matches one of ours.
    
    Preserves ALL other content byte-for-byte.
    A block = header line + indented continuation lines + trailing blank line.
    """
    lines = text.splitlines(keepends=True)
    cleaned = []
    skip_block = False
    
    for line in lines:
        stripped = line.strip()
        
        if stripped and not line[0:1].isspace() and ':' in stripped:
            if stripped in headers_to_remove:
                skip_block = True
                continue
            else:
                skip_block = False
        
        if skip_block:
            if not stripped:
                skip_block = False
                continue
            elif line[0:1].isspace():
                continue
            else:
                skip_block = False
        
        cleaned.append(line)
    
    return ''.join(cleaned)


def _build_webhook_fallback():
    """Build fallback manual commands for webhook setup."""
    import base64
    body_tpl = '{"title":"{{ escape title }}","message":"{{ escape message }}","severity":"{{ severity }}","timestamp":"{{ timestamp }}","fields":{{ json fields }}}'
    body_b64 = base64.b64encode(body_tpl.encode()).decode()
    return [
        "# 1. Append to END of /etc/pve/notifications.cfg",
        "#    (do NOT delete existing content):",
        "",
        f"webhook: {_PVE_ENDPOINT_ID}",
        f"\tbody {body_b64}",
        f"\tmethod post",
        f"\turl {_PVE_WEBHOOK_URL}",
        "",
        f"matcher: {_PVE_MATCHER_ID}",
        f"\ttarget {_PVE_ENDPOINT_ID}",
        "\tmode all",
        "",
        "# 2. Append to /etc/pve/priv/notifications.cfg :",
        f"webhook: {_PVE_ENDPOINT_ID}",
    ]


def setup_pve_webhook_core() -> dict:
    """Core logic to configure PVE webhook. Callable from anywhere.
    
    Returns dict with 'configured', 'error', 'fallback_commands' keys.
    Idempotent: safe to call multiple times.
    """
    import secrets as secrets_mod
    
    result = {
        'configured': False,
        'endpoint_id': _PVE_ENDPOINT_ID,
        'matcher_id': _PVE_MATCHER_ID,
        'url': _PVE_WEBHOOK_URL,
        'fallback_commands': [],
        'error': None,
    }
    
    try:
        # ── Step 1: Ensure webhook secret exists (for our own internal use) ──
        secret = notification_manager.get_webhook_secret()
        if not secret:
            secret = secrets_mod.token_urlsafe(32)
            notification_manager._save_setting('webhook_secret', secret)
        
        # ── Step 2: Read main config ──
        cfg_text, err = _pve_read_file(_PVE_NOTIFICATIONS_CFG)
        if err:
            result['error'] = err
            result['fallback_commands'] = _build_webhook_fallback()
            return result
        
        # ── Step 3: Read priv config (to clean up any broken blocks we wrote before) ──
        priv_text, err = _pve_read_file(_PVE_PRIV_CFG)
        if err:
            priv_text = None
        
        # ── Step 4: Create backups before ANY modification ──
        _pve_backup_file(_PVE_NOTIFICATIONS_CFG)
        if priv_text is not None:
            _pve_backup_file(_PVE_PRIV_CFG)
        
        # ── Step 5: Remove any previous proxmenux blocks from BOTH files ──
        cleaned_cfg = _pve_remove_our_blocks(cfg_text, _PVE_OUR_HEADERS)
        
        if priv_text is not None:
            cleaned_priv = _pve_remove_our_blocks(priv_text, _PVE_OUR_HEADERS)
        
        # ── Step 6: Build new blocks ──
        # Exact format from a real working PVE server:
        #   webhook: name
        #   \tmethod post
        #   \turl http://...
        #
        # NO header lines -- localhost webhook doesn't need them.
        # PVE header format is: header name=X-Key,value=<base64>
        # PVE secret format is: secret name=key,value=<base64>
        # Neither is needed for localhost calls.
        
        # PVE stores body as base64 in the config file.
        # {{ escape title/message }} -- JSON-safe escaping of quotes/newlines.
        # {{ json fields }} -- renders ALL PVE metadata as a JSON object
        #   (type, hostname, job-id). This is a single Handlebars helper
        #   that always works, even if fields is empty (renders {}).
        import base64
        body_template = '{"title":"{{ escape title }}","message":"{{ escape message }}","severity":"{{ severity }}","timestamp":"{{ timestamp }}","fields":{{ json fields }}}'
        body_b64 = base64.b64encode(body_template.encode()).decode()
        
        endpoint_block = (
            f"webhook: {_PVE_ENDPOINT_ID}\n"
            f"\tbody {body_b64}\n"
            f"\tmethod post\n"
            f"\turl {_PVE_WEBHOOK_URL}\n"
        )
        
        matcher_block = (
            f"matcher: {_PVE_MATCHER_ID}\n"
            f"\ttarget {_PVE_ENDPOINT_ID}\n"
            f"\tmode all\n"
        )
        
        # ── Step 7: Append our blocks to cleaned main config ──
        if cleaned_cfg and not cleaned_cfg.endswith('\n'):
            cleaned_cfg += '\n'
        if cleaned_cfg and not cleaned_cfg.endswith('\n\n'):
            cleaned_cfg += '\n'
        
        new_cfg = cleaned_cfg + endpoint_block + '\n' + matcher_block
        
        # ── Step 8: Write main config ──
        try:
            with open(_PVE_NOTIFICATIONS_CFG, 'w') as f:
                f.write(new_cfg)
        except PermissionError:
            result['error'] = f'Permission denied writing {_PVE_NOTIFICATIONS_CFG}'
            result['fallback_commands'] = _build_webhook_fallback()
            return result
        except Exception as e:
            try:
                with open(_PVE_NOTIFICATIONS_CFG, 'w') as f:
                    f.write(cfg_text)
            except Exception:
                pass
            result['error'] = str(e)
            result['fallback_commands'] = _build_webhook_fallback()
            return result
        
        # ── Step 9: Write priv config with our webhook entry ──
        # PVE REQUIRES a matching block in priv/notifications.cfg for every
        # webhook endpoint, even if it has no secrets. Without it PVE throws:
        #   "Could not instantiate endpoint: private config does not exist"
        priv_block = (
            f"webhook: {_PVE_ENDPOINT_ID}\n"
        )
        
        if priv_text is not None:
            # Start from cleaned priv (our old blocks removed)
            if cleaned_priv and not cleaned_priv.endswith('\n'):
                cleaned_priv += '\n'
            if cleaned_priv and not cleaned_priv.endswith('\n\n'):
                cleaned_priv += '\n'
            new_priv = cleaned_priv + priv_block
        else:
            new_priv = priv_block
        
        try:
            with open(_PVE_PRIV_CFG, 'w') as f:
                f.write(new_priv)
        except PermissionError:
            result['error'] = f'Permission denied writing {_PVE_PRIV_CFG}'
            result['fallback_commands'] = _build_webhook_fallback()
            return result
        except Exception:
            pass
        
        result['configured'] = True
        result['secret'] = secret
        return result
    
    except Exception as e:
        result['error'] = str(e)
        result['fallback_commands'] = _build_webhook_fallback()
        return result


@notification_bp.route('/api/notifications/proxmox/setup-webhook', methods=['POST'])
def setup_proxmox_webhook():
    """HTTP endpoint wrapper for webhook setup."""
    return jsonify(setup_pve_webhook_core()), 200


def cleanup_pve_webhook_core() -> dict:
    """Core logic to remove PVE webhook blocks. Callable from anywhere.
    
    Returns dict with 'cleaned', 'error' keys.
    Only removes blocks named 'proxmenux-webhook' / 'proxmenux-default'.
    """
    result = {'cleaned': False, 'error': None}
    
    try:
        # Read both files
        cfg_text, err = _pve_read_file(_PVE_NOTIFICATIONS_CFG)
        if err:
            result['error'] = err
            return result
        
        priv_text, err = _pve_read_file(_PVE_PRIV_CFG)
        if err:
            priv_text = None
        
        # Check if our blocks actually exist before doing anything
        has_our_blocks = any(
            h in cfg_text for h in [f'webhook: {_PVE_ENDPOINT_ID}', f'matcher: {_PVE_MATCHER_ID}']
        )
        has_priv_blocks = priv_text and f'webhook: {_PVE_ENDPOINT_ID}' in priv_text
        
        if not has_our_blocks and not has_priv_blocks:
            result['cleaned'] = True
            return result
        
        # Backup before modification
        _pve_backup_file(_PVE_NOTIFICATIONS_CFG)
        if priv_text is not None:
            _pve_backup_file(_PVE_PRIV_CFG)
        
        # Remove our blocks
        if has_our_blocks:
            cleaned_cfg = _pve_remove_our_blocks(cfg_text, _PVE_OUR_HEADERS)
            try:
                with open(_PVE_NOTIFICATIONS_CFG, 'w') as f:
                    f.write(cleaned_cfg)
            except PermissionError:
                result['error'] = f'Permission denied writing {_PVE_NOTIFICATIONS_CFG}'
                return result
            except Exception as e:
                # Rollback
                try:
                    with open(_PVE_NOTIFICATIONS_CFG, 'w') as f:
                        f.write(cfg_text)
                except Exception:
                    pass
                result['error'] = str(e)
                return result
        
        if has_priv_blocks and priv_text is not None:
            cleaned_priv = _pve_remove_our_blocks(priv_text, _PVE_OUR_HEADERS)
            try:
                with open(_PVE_PRIV_CFG, 'w') as f:
                    f.write(cleaned_priv)
            except Exception:
                pass  # Best-effort
        
        result['cleaned'] = True
        return result
    
    except Exception as e:
        result['error'] = str(e)
        return result


@notification_bp.route('/api/notifications/proxmox/cleanup-webhook', methods=['POST'])
def cleanup_proxmox_webhook():
    """HTTP endpoint wrapper for webhook cleanup."""
    return jsonify(cleanup_pve_webhook_core()), 200


@notification_bp.route('/api/notifications/proxmox/read-cfg', methods=['GET'])
def read_pve_notification_cfg():
    """Diagnostic: return raw content of PVE notification config files.
    
    GET /api/notifications/proxmox/read-cfg
    Returns both notifications.cfg and priv/notifications.cfg content.
    """
    import os
    
    files = {
        'notifications_cfg': '/etc/pve/notifications.cfg',
        'priv_cfg': '/etc/pve/priv/notifications.cfg',
    }
    
    # Also look for any backups we created
    backup_dir = '/etc/pve'
    priv_backup_dir = '/etc/pve/priv'
    
    result = {}
    for key, path in files.items():
        try:
            with open(path, 'r') as f:
                result[key] = {
                    'path': path,
                    'content': f.read(),
                    'size': os.path.getsize(path),
                    'error': None,
                }
        except FileNotFoundError:
            result[key] = {'path': path, 'content': None, 'size': 0, 'error': 'file_not_found'}
        except PermissionError:
            result[key] = {'path': path, 'content': None, 'size': 0, 'error': 'permission_denied'}
        except Exception as e:
            result[key] = {'path': path, 'content': None, 'size': 0, 'error': str(e)}
    
    # Find backups
    backups = []
    for d in [backup_dir, priv_backup_dir]:
        try:
            for fname in sorted(os.listdir(d)):
                if 'proxmenux_backup' in fname:
                    fpath = os.path.join(d, fname)
                    try:
                        with open(fpath, 'r') as f:
                            backups.append({
                                'path': fpath,
                                'content': f.read(),
                                'size': os.path.getsize(fpath),
                            })
                    except Exception:
                        backups.append({'path': fpath, 'content': None, 'error': 'read_failed'})
        except Exception:
            pass
    
    result['backups'] = backups
    return jsonify(result), 200


@notification_bp.route('/api/notifications/proxmox/restore-cfg', methods=['POST'])
def restore_pve_notification_cfg():
    """Restore PVE notification config from our backup.
    
    POST /api/notifications/proxmox/restore-cfg
    Finds the most recent proxmenux_backup and restores it.
    """
    import os
    import shutil
    
    files_to_restore = {
        '/etc/pve': '/etc/pve/notifications.cfg',
        '/etc/pve/priv': '/etc/pve/priv/notifications.cfg',
    }
    
    restored = []
    errors = []
    
    for search_dir, target_path in files_to_restore.items():
        try:
            candidates = sorted([
                f for f in os.listdir(search_dir)
                if 'proxmenux_backup' in f and f.startswith('notifications.cfg')
            ], reverse=True)
            
            if candidates:
                backup_path = os.path.join(search_dir, candidates[0])
                shutil.copy2(backup_path, target_path)
                restored.append({'target': target_path, 'from_backup': backup_path})
            else:
                errors.append({'target': target_path, 'error': 'no_backup_found'})
        except Exception as e:
            errors.append({'target': target_path, 'error': str(e)})
    
    return jsonify({
        'restored': restored,
        'errors': errors,
        'success': len(errors) == 0 and len(restored) > 0,
    }), 200


@notification_bp.route('/api/notifications/webhook', methods=['POST'])
def proxmox_webhook():
    """Receive native Proxmox VE notification webhooks (hardened).
    
    Security layers:
      Localhost (127.0.0.1 / ::1): rate limiting only.
        PVE calls us on localhost and cannot send custom auth headers,
        so we trust the loopback interface (only local processes can reach it).
      Remote: rate limiting + shared secret + timestamp + replay + IP allowlist.
    """
    _reject = lambda code, error, status: (jsonify({'accepted': False, 'error': error}), status)
    
    client_ip = request.remote_addr or ''
    is_localhost = client_ip in ('127.0.0.1', '::1')
    
    # ── Layer 1: Rate limiting (always) ──
    if not _webhook_limiter.allow():
        resp = jsonify({'accepted': False, 'error': 'rate_limited'})
        resp.headers['Retry-After'] = '60'
        return resp, 429
    
    # ── Layers 2-5: Remote-only checks ──
    if not is_localhost:
        # Layer 2: Shared secret
        try:
            configured_secret = notification_manager.get_webhook_secret()
        except Exception:
            configured_secret = ''
        
        if configured_secret:
            request_secret = request.headers.get('X-Webhook-Secret', '')
            if not request_secret:
                return _reject(401, 'missing_secret', 401)
            if not hmac.compare_digest(configured_secret, request_secret):
                return _reject(401, 'invalid_secret', 401)
        
        # Layer 3: Anti-replay timestamp
        ts_header = request.headers.get('X-ProxMenux-Timestamp', '')
        if not ts_header:
            return _reject(401, 'missing_timestamp', 401)
        try:
            ts_value = int(ts_header)
        except (ValueError, TypeError):
            return _reject(401, 'invalid_timestamp', 401)
        if abs(time.time() - ts_value) > _TIMESTAMP_MAX_DRIFT:
            return _reject(401, 'timestamp_expired', 401)
        
        # Layer 4: Replay cache
        raw_body = request.get_data(as_text=True) or ''
        signature = hashlib.sha256(f"{ts_value}:{raw_body}".encode(errors='replace')).hexdigest()
        if _replay_cache.check_and_record(signature):
            return _reject(409, 'replay_detected', 409)
        
        # Layer 5: IP allowlist
        try:
            allowed_ips = notification_manager.get_webhook_allowed_ips()
            if allowed_ips and client_ip not in allowed_ips:
                return _reject(403, 'forbidden_ip', 403)
        except Exception:
            pass
    
    # ── Parse and process payload ──
    try:
        content_type = request.content_type or ''
        raw_data = request.get_data(as_text=True) or ''
        
        # Try JSON first
        payload = request.get_json(silent=True) or {}
        
        # If not JSON, try form data
        if not payload:
            payload = dict(request.form)
        
        # If still empty, try parsing raw data as JSON (PVE may not set Content-Type)
        if not payload and raw_data:
            import json
            try:
                payload = json.loads(raw_data)
            except (json.JSONDecodeError, ValueError):
                # PVE's {{ message }} may contain unescaped newlines/quotes
                # that break JSON. Try to repair common issues.
                try:
                    repaired = raw_data.replace('\n', '\\n').replace('\r', '\\r')
                    payload = json.loads(repaired)
                except (json.JSONDecodeError, ValueError):
                    # Try to extract fields with regex from broken JSON
                    import re
                    title_m = re.search(r'"title"\s*:\s*"([^"]*)"', raw_data)
                    sev_m = re.search(r'"severity"\s*:\s*"([^"]*)"', raw_data)
                    if title_m:
                        payload = {
                            'title': title_m.group(1),
                            'body': raw_data[:1000],
                            'severity': sev_m.group(1) if sev_m else 'info',
                            'source': 'proxmox_hook',
                        }
        
        # If still empty, try to salvage data from raw body
        if not payload:
            if raw_data:
                # Last resort: treat raw text as the message body
                payload = {
                    'title': 'PVE Notification',
                    'body': raw_data[:1000],
                    'severity': 'info',
                    'source': 'proxmox_hook',
                }
            else:
                return _reject(400, 'empty_payload', 400)
        
        result = notification_manager.process_webhook(payload)
        # Always return 200 to PVE -- a non-200 makes PVE report the webhook as broken.
        # The 'accepted' field in the JSON body indicates actual processing status.
        return jsonify(result), 200
    except Exception as e:
        # Still return 200 to avoid PVE flagging the webhook as broken
        return jsonify({'accepted': False, 'error': 'internal_error', 'detail': str(e)}), 200


# ─── Internal Shutdown Event Endpoint ─────────────────────────────

@notification_bp.route('/api/internal/shutdown-event', methods=['POST'])
def internal_shutdown_event():
    """
    Internal endpoint called by systemd ExecStop script to emit shutdown/reboot notification.
    This allows the service to send a notification BEFORE it terminates.
    
    Only accepts requests from localhost (127.0.0.1) for security.
    """
    # Security: Only allow localhost
    remote_addr = request.remote_addr
    if remote_addr not in ('127.0.0.1', '::1', 'localhost'):
        return jsonify({'error': 'forbidden', 'detail': 'localhost only'}), 403
    
    try:
        data = request.get_json(silent=True) or {}
        event_type = data.get('event_type', 'system_shutdown')
        hostname = data.get('hostname', 'unknown')
        reason = data.get('reason', 'System is shutting down.')
        
        # Validate event type
        if event_type not in ('system_shutdown', 'system_reboot'):
            return jsonify({'error': 'invalid_event_type'}), 400
        
        # Emit the notification directly through notification_manager
        notification_manager.emit_event(
            event_type=event_type,
            severity='INFO',
            data={
                'hostname': hostname,
                'reason': reason,
            },
            source='systemd',
            entity='node',
            entity_id='',
        )
        
        return jsonify({'success': True, 'event_type': event_type}), 200
    except Exception as e:
        return jsonify({'error': 'internal_error', 'detail': str(e)}), 500
