"""
Flask Authentication Routes
Provides REST API endpoints for authentication management
"""

import logging
import logging.handlers
import os
import subprocess
import threading
import time
from flask import Blueprint, jsonify, request
import auth_manager
import jwt
import datetime

# Dedicated logger for auth failures (Fail2Ban reads this file)
auth_logger = logging.getLogger("proxmenux-auth")
auth_logger.setLevel(logging.WARNING)

# Handler 1: File for Fail2Ban
_auth_file_handler = logging.FileHandler("/var/log/proxmenux-auth.log")
_auth_file_handler.setFormatter(logging.Formatter("%(asctime)s proxmenux-auth: %(message)s"))
auth_logger.addHandler(_auth_file_handler)

# Handler 2: Syslog for JournalWatcher notifications
# This sends to the systemd journal so notification_events.py can detect auth failures
try:
    _auth_syslog_handler = logging.handlers.SysLogHandler(address='/dev/log', facility=logging.handlers.SysLogHandler.LOG_AUTH)
    _auth_syslog_handler.setFormatter(logging.Formatter("proxmenux-auth: %(message)s"))
    _auth_syslog_handler.ident = "proxmenux-auth"
    auth_logger.addHandler(_auth_syslog_handler)
except Exception:
    pass  # Syslog may not be available in all environments


def _get_client_ip():
    """Get the real client IP, supporting reverse proxies (X-Forwarded-For, X-Real-IP)"""
    forwarded = request.headers.get("X-Forwarded-For", "")
    if forwarded:
        # First IP in the chain is the real client
        return forwarded.split(",")[0].strip()
    real_ip = request.headers.get("X-Real-IP", "")
    if real_ip:
        return real_ip.strip()
    return request.remote_addr or "unknown"

auth_bp = Blueprint('auth', __name__)

@auth_bp.route('/api/auth/status', methods=['GET'])
def auth_status():
    """Get current authentication status"""
    try:
        status = auth_manager.get_auth_status()
        
        token = request.headers.get('Authorization', '').replace('Bearer ', '')
        if token:
            username = auth_manager.verify_token(token)
            if username:
                status['authenticated'] = True
        
        return jsonify(status)
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500


# -------------------------------------------------------------------
# SSL/HTTPS Certificate Management
# -------------------------------------------------------------------

@auth_bp.route('/api/ssl/status', methods=['GET'])
def ssl_status():
    """Get current SSL configuration status and detect available certificates"""
    try:
        config = auth_manager.load_ssl_config()
        detection = auth_manager.detect_proxmox_certificates()
        
        return jsonify({
            "success": True,
            "ssl_enabled": config.get("enabled", False),
            "source": config.get("source", "none"),
            "cert_path": config.get("cert_path", ""),
            "key_path": config.get("key_path", ""),
            "proxmox_available": detection.get("proxmox_available", False),
            "proxmox_cert": detection.get("proxmox_cert", ""),
            "proxmox_key": detection.get("proxmox_key", ""),
            "cert_info": detection.get("cert_info")
        })
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500


def _schedule_service_restart(delay=1.5):
    """Schedule a restart of the monitor service via systemctl after a short delay.
    This gives time for the HTTP response to reach the client before the process restarts."""
    def _do_restart():
        time.sleep(delay)
        print("[ProxMenux] Restarting monitor service to apply SSL changes...")
        # Use systemctl restart which properly stops and starts the service.
        # This works because systemd manages proxmenux-monitor.service.
        try:
            subprocess.Popen(
                ["systemctl", "restart", "proxmenux-monitor"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
        except Exception as e:
            print(f"[ProxMenux] Failed to restart via systemctl: {e}")
            # Fallback: try to restart the process directly
            os.kill(os.getpid(), 15)  # SIGTERM
    
    t = threading.Thread(target=_do_restart, daemon=True)
    t.start()


@auth_bp.route('/api/ssl/configure', methods=['POST'])
def ssl_configure():
    """Configure SSL with Proxmox or custom certificates"""
    try:
        data = request.json or {}
        source = data.get("source", "proxmox")
        auto_restart = data.get("auto_restart", True)
        
        if source == "proxmox":
            cert_path = auth_manager.PROXMOX_CERT_PATH
            key_path = auth_manager.PROXMOX_KEY_PATH
        elif source == "custom":
            cert_path = data.get("cert_path", "")
            key_path = data.get("key_path", "")
        else:
            return jsonify({"success": False, "message": "Invalid source. Use 'proxmox' or 'custom'."}), 400
        
        success, message = auth_manager.configure_ssl(cert_path, key_path, source)
        
        if success:
            if auto_restart:
                _schedule_service_restart()
            return jsonify({
                "success": True,
                "message": "SSL enabled. The service is restarting...",
                "restarting": auto_restart,
                "new_protocol": "https"
            })
        else:
            return jsonify({"success": False, "message": message}), 400
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500


@auth_bp.route('/api/ssl/disable', methods=['POST'])
def ssl_disable():
    """Disable SSL and return to HTTP"""
    try:
        data = request.json or {}
        auto_restart = data.get("auto_restart", True)
        
        success, message = auth_manager.disable_ssl()
        
        if success:
            if auto_restart:
                _schedule_service_restart()
            return jsonify({
                "success": True,
                "message": "SSL disabled. The service is restarting...",
                "restarting": auto_restart,
                "new_protocol": "http"
            })
        else:
            return jsonify({"success": False, "message": message}), 400
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500


@auth_bp.route('/api/ssl/validate', methods=['POST'])
def ssl_validate():
    """Validate custom certificate and key file paths"""
    try:
        data = request.json or {}
        cert_path = data.get("cert_path", "")
        key_path = data.get("key_path", "")
        
        valid, message = auth_manager.validate_certificate_files(cert_path, key_path)
        
        return jsonify({"success": valid, "message": message})
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500



@auth_bp.route('/api/auth/decline', methods=['POST'])
def auth_decline():
    """Decline authentication setup"""
    try:
        success, message = auth_manager.decline_auth()
        
        if success:
            return jsonify({"success": True, "message": message})
        else:
            return jsonify({"success": False, "message": message}), 400
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500


@auth_bp.route('/api/auth/login', methods=['POST'])
def auth_login():
    """Authenticate user and return JWT token"""
    try:
        data = request.json
        username = data.get('username')
        password = data.get('password')
        totp_token = data.get('totp_token')  # Optional 2FA token
        
        success, token, requires_totp, message = auth_manager.authenticate(username, password, totp_token)
        
        if success:
            return jsonify({"success": True, "token": token, "message": message})
        elif requires_totp:
            # First step: password OK, requesting TOTP code (not a failure)
            return jsonify({"success": False, "requires_totp": True, "message": message}), 200
        else:
            # Authentication failure (wrong password or wrong TOTP code)
            client_ip = _get_client_ip()
            auth_logger.warning(
                "authentication failure; rhost=%s user=%s",
                client_ip, username or "unknown"
            )
            # If user submitted a TOTP token that was wrong, tell frontend
            # to keep showing the TOTP field (not go back to password step)
            is_totp_failure = totp_token and "2FA" in message
            return jsonify({
                "success": False,
                "message": message,
                "requires_totp": is_totp_failure
            }), 401
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500


@auth_bp.route('/api/auth/setup', methods=['POST'])
def auth_setup():
    """Set up authentication with username and password (create user + enable auth)"""
    try:
        data = request.json
        username = data.get('username')
        password = data.get('password')

        success, message = auth_manager.setup_auth(username, password)

        if success:
            # Generate a token so the user is logged in immediately
            token = auth_manager.generate_token(username)
            return jsonify({"success": True, "token": token, "message": message})
        else:
            return jsonify({"success": False, "error": message}), 400
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500


@auth_bp.route('/api/auth/enable', methods=['POST'])
def auth_enable():
    """Enable authentication (must already be configured)"""
    try:
        success, message = auth_manager.enable_auth()
        
        if success:
            return jsonify({"success": True, "message": message})
        else:
            return jsonify({"success": False, "message": message}), 400
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500


@auth_bp.route('/api/auth/disable', methods=['POST'])
def auth_disable():
    """Disable authentication"""
    try:
        token = request.headers.get('Authorization', '').replace('Bearer ', '')
        if not token or not auth_manager.verify_token(token):
            return jsonify({"success": False, "message": "Unauthorized"}), 401
            
        success, message = auth_manager.disable_auth()
        
        if success:
            return jsonify({"success": True, "message": message})
        else:
            return jsonify({"success": False, "message": message}), 400
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500


@auth_bp.route('/api/auth/change-password', methods=['POST'])
def auth_change_password():
    """Change authentication password"""
    try:
        data = request.json
        old_password = data.get('old_password')
        new_password = data.get('new_password')
        
        success, message = auth_manager.change_password(old_password, new_password)
        
        if success:
            return jsonify({"success": True, "message": message})
        else:
            return jsonify({"success": False, "message": message}), 400
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500


@auth_bp.route('/api/auth/skip', methods=['POST'])
def auth_skip():
    """Skip authentication setup (same as decline)"""
    try:
        success, message = auth_manager.decline_auth()
        
        if success:
            # Return success with clear indication that APIs should be accessible
            return jsonify({
                "success": True, 
                "message": message,
                "auth_declined": True  # Add explicit flag for frontend
            })
        else:
            return jsonify({"success": False, "message": message}), 400
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500


@auth_bp.route('/api/auth/totp/setup', methods=['POST'])
def totp_setup():
    """Initialize TOTP setup for a user"""
    try:
        token = request.headers.get('Authorization', '').replace('Bearer ', '')
        username = auth_manager.verify_token(token)
        
        if not username:
            return jsonify({"success": False, "message": "Unauthorized"}), 401
        
        success, secret, qr_code, backup_codes, message = auth_manager.setup_totp(username)
        
        if success:
            return jsonify({
                "success": True,
                "secret": secret,
                "qr_code": qr_code,
                "backup_codes": backup_codes,
                "message": message
            })
        else:
            return jsonify({"success": False, "message": message}), 400
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500


@auth_bp.route('/api/auth/totp/enable', methods=['POST'])
def totp_enable():
    """Enable TOTP after verification"""
    try:
        token = request.headers.get('Authorization', '').replace('Bearer ', '')
        username = auth_manager.verify_token(token)
        
        if not username:
            return jsonify({"success": False, "message": "Unauthorized"}), 401
        
        data = request.json
        verification_token = data.get('token')
        
        if not verification_token:
            return jsonify({"success": False, "message": "Verification token required"}), 400
        
        success, message = auth_manager.enable_totp(username, verification_token)
        
        if success:
            return jsonify({"success": True, "message": message})
        else:
            return jsonify({"success": False, "message": message}), 400
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500


@auth_bp.route('/api/auth/totp/disable', methods=['POST'])
def totp_disable():
    """Disable TOTP (requires password confirmation)"""
    try:
        token = request.headers.get('Authorization', '').replace('Bearer ', '')
        username = auth_manager.verify_token(token)
        
        if not username:
            return jsonify({"success": False, "message": "Unauthorized"}), 401
        
        data = request.json
        password = data.get('password')
        
        if not password:
            return jsonify({"success": False, "message": "Password required"}), 400
        
        success, message = auth_manager.disable_totp(username, password)
        
        if success:
            return jsonify({"success": True, "message": message})
        else:
            return jsonify({"success": False, "message": message}), 400
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500


@auth_bp.route('/api/auth/generate-api-token', methods=['POST'])
def generate_api_token():
    """Generate a long-lived API token for external integrations (Homepage, Home Assistant, etc.)"""
    try:
        auth_header = request.headers.get('Authorization', '')
        token = auth_header.replace('Bearer ', '')
        
        if not token:
            return jsonify({"success": False, "message": "Unauthorized. Please log in first."}), 401
        
        username = auth_manager.verify_token(token)
        
        if not username:
            return jsonify({"success": False, "message": "Invalid or expired session. Please log in again."}), 401
        
        data = request.json
        password = data.get('password')
        totp_token = data.get('totp_token')  # Optional 2FA token
        token_name = data.get('token_name', 'API Token')  # Optional token description
        
        if not password:
            return jsonify({"success": False, "message": "Password is required"}), 400
        
        # Authenticate user with password and optional 2FA
        success, _, requires_totp, message = auth_manager.authenticate(username, password, totp_token)
        
        if success:
            # Generate a long-lived token (1 year expiration)
            api_token = jwt.encode({
                'username': username,
                'token_name': token_name,
                'exp': datetime.datetime.utcnow() + datetime.timedelta(days=365),
                'iat': datetime.datetime.utcnow()
            }, auth_manager.JWT_SECRET, algorithm='HS256')
            
            # Store token metadata for listing and revocation
            auth_manager.store_api_token_metadata(api_token, token_name)
            
            return jsonify({
                "success": True, 
                "token": api_token,
                "token_name": token_name,
                "expires_in": "365 days",
                "message": "API token generated successfully. Store this token securely, it will not be shown again."
            })
        elif requires_totp:
            return jsonify({"success": False, "requires_totp": True, "message": message}), 200
        else:
            return jsonify({"success": False, "message": message}), 401
    except Exception as e:
        print(f"[ERROR] generate_api_token: {str(e)}")  # Log error for debugging
        return jsonify({"success": False, "message": f"Internal error: {str(e)}"}), 500


@auth_bp.route('/api/auth/api-tokens', methods=['GET'])
def list_api_tokens():
    """List all generated API tokens (metadata only, no actual token values)"""
    try:
        token = request.headers.get('Authorization', '').replace('Bearer ', '')
        if not token or not auth_manager.verify_token(token):
            return jsonify({"success": False, "message": "Unauthorized"}), 401
        
        tokens = auth_manager.list_api_tokens()
        return jsonify({"success": True, "tokens": tokens})
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500


@auth_bp.route('/api/auth/api-tokens/<token_id>', methods=['DELETE'])
def revoke_api_token_route(token_id):
    """Revoke an API token by its ID"""
    try:
        token = request.headers.get('Authorization', '').replace('Bearer ', '')
        if not token or not auth_manager.verify_token(token):
            return jsonify({"success": False, "message": "Unauthorized"}), 401
        
        success, message = auth_manager.revoke_api_token(token_id)
        
        if success:
            return jsonify({"success": True, "message": message})
        else:
            return jsonify({"success": False, "message": message}), 400
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500
