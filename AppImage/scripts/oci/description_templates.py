#!/usr/bin/env python3
"""
ProxMenux - HTML Description Templates for OCI Containers
==========================================================
Generates beautiful HTML descriptions for the Proxmox Notes panel.
Can be used from both Python (oci_manager.py) and bash scripts.

Usage from bash:
  python3 description_templates.py --app-id "secure-gateway" --hostname "my-gateway"
  
Usage from Python:
  from description_templates import generate_description
  html = generate_description(app_def, container_def, hostname)
"""

import sys
import json
import argparse
import urllib.parse
from pathlib import Path
from typing import Dict, Optional

# Default paths
CATALOG_PATH = Path(__file__).parent / "catalog.json"


def get_shield_icon_svg(color: str = "#0EA5E9") -> str:
    """Generate a shield icon SVG with checkmark."""
    return f"""<svg xmlns='http://www.w3.org/2000/svg' width='48' height='48' viewBox='0 0 24 24' fill='none' stroke='{color}' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z'/><path d='M9 12l2 2 4-4'/></svg>"""


def get_default_icon_svg(color: str = "#0EA5E9") -> str:
    """Generate a default container icon SVG."""
    return f"""<svg xmlns='http://www.w3.org/2000/svg' width='48' height='48' viewBox='0 0 24 24' fill='none' stroke='{color}' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z'/><polyline points='3.27 6.96 12 12.01 20.73 6.96'/><line x1='12' y1='22.08' x2='12' y2='12'/></svg>"""


# Pre-defined icon types
ICON_TYPES = {
    "shield": get_shield_icon_svg,
    "container": get_default_icon_svg,
    "default": get_default_icon_svg,
}


def generate_description(
    app_def: Dict,
    container_def: Optional[Dict] = None,
    hostname: str = "",
    extra_info: str = ""
) -> str:
    """
    Generate HTML description for Proxmox Notes panel.
    
    Args:
        app_def: Application definition from catalog
        container_def: Container definition (optional)
        hostname: Container hostname
        extra_info: Additional info to display (e.g., disk info)
    
    Returns:
        HTML string for the description
    """
    # Extract app info
    app_name = app_def.get("name", "ProxMenux App")
    app_subtitle = app_def.get("subtitle", "")
    app_color = app_def.get("color", "#0EA5E9")
    app_icon_type = app_def.get("icon_type", "default")
    doc_url = app_def.get("documentation_url", "https://macrimi.github.io/ProxMenux/")
    code_url = app_def.get("code_url", "https://github.com/MacRimi/ProxMenux")
    installer_url = app_def.get("installer_url", "")
    kofi_url = "https://ko-fi.com/macrimi"
    
    # Get the icon SVG
    icon_func = ICON_TYPES.get(app_icon_type, ICON_TYPES["default"])
    icon_svg = icon_func(app_color)
    icon_data = "data:image/svg+xml," + urllib.parse.quote(icon_svg)
    
    # Build badge buttons
    badges = []
    badges.append(f"<a href='{doc_url}' target='_blank'><img src='https://img.shields.io/badge/📚_Docs-blue' alt='Docs'></a>")
    badges.append(f"<a href='{code_url}' target='_blank'><img src='https://img.shields.io/badge/💻_Code-green' alt='Code'></a>")
    
    if installer_url:
        badges.append(f"<a href='{installer_url}' target='_blank'><img src='https://img.shields.io/badge/📦_Installer-orange' alt='Installer'></a>")
    
    badges.append(f"<a href='{kofi_url}' target='_blank'><img src='https://img.shields.io/badge/☕_Ko--fi-red' alt='Ko-fi'></a>")
    
    badges_html = "\n".join(badges)
    
    # Build footer info
    footer_parts = []
    if hostname:
        footer_parts.append(f"Hostname: {hostname}")
    if extra_info:
        footer_parts.append(extra_info)
    footer_html = "<br>".join(footer_parts) if footer_parts else ""
    
    # Build the complete HTML
    html = f"""<div align='center'>
<table style='width: 100%; border-collapse: collapse;'>
<tr>
<td style='width: 100px; vertical-align: middle;'>
<img src="/images/design-mode/logo_desc.png" alt='ProxMenux Logo' style='height: 100px;'>
</td>
<td style='vertical-align: middle;'>
<h1 style='margin: 0;'>{app_name}</h1>
<p style='margin: 0;'>Created with ProxMenux</p>
</td>
</tr>
</table>

<div style='margin: 15px 0; padding: 10px; background: #2d2d2d; border-radius: 8px; display: inline-block;'>
<table style='border-collapse: collapse;'>
<tr>
<td style='vertical-align: middle; padding-right: 10px;'>
<img src='{icon_data}' alt='Icon' style='height: 48px;'>
</td>
<td style='vertical-align: middle; text-align: left;'>
<span style='font-size: 18px; font-weight: bold; color: {app_color};'>{app_name}</span><br>
<span style='color: #9ca3af;'>{app_subtitle}</span>
</td>
</tr>
</table>
</div>

<p>
{badges_html}
</p>
"""
    
    if footer_html:
        html += f"""
<p style='color: #6b7280; font-size: 12px;'>
{footer_html}
</p>
"""
    
    html += "</div>"
    
    return html


def generate_vm_description(
    vm_name: str,
    vm_version: str = "",
    doc_url: str = "",
    code_url: str = "",
    installer_url: str = "",
    extra_info: str = "",
    icon_url: str = ""
) -> str:
    """
    Generate HTML description for VMs (like ZimaOS).
    
    Args:
        vm_name: Name of the VM
        vm_version: Version string
        doc_url: Documentation URL
        code_url: Code repository URL
        installer_url: Installer URL
        extra_info: Additional info (e.g., disk info)
        icon_url: Custom icon URL for the VM
    
    Returns:
        HTML string for the description
    """
    # Build badge buttons
    badges = []
    if doc_url:
        badges.append(f"<a href='{doc_url}' target='_blank'><img src='https://img.shields.io/badge/📚_Docs-blue' alt='Docs'></a>")
    if code_url:
        badges.append(f"<a href='{code_url}' target='_blank'><img src='https://img.shields.io/badge/💻_Code-green' alt='Code'></a>")
    if installer_url:
        badges.append(f"<a href='{installer_url}' target='_blank'><img src='https://img.shields.io/badge/📦_Installer-orange' alt='Installer'></a>")
    badges.append("<a href='https://ko-fi.com/macrimi' target='_blank'><img src='https://img.shields.io/badge/☕_Ko--fi-red' alt='Ko-fi'></a>")
    
    badges_html = "\n".join(badges)
    
    # Version line
    version_html = f"<p style='margin: 0;'>{vm_version}</p>" if vm_version else ""
    
    # Extra info
    extra_html = f"<p style='color: #6b7280; font-size: 12px;'>{extra_info}</p>" if extra_info else ""
    
    html = f"""<div align='center'>
<table style='width: 100%; border-collapse: collapse;'>
<tr>
<td style='width: 100px; vertical-align: middle;'>
<img src="/images/design-mode/logo_desc.png" alt='ProxMenux Logo' style='height: 100px;'>
</td>
<td style='vertical-align: middle;'>
<h1 style='margin: 0;'>{vm_name}</h1>
<p style='margin: 0;'>Created with ProxMenux</p>
{version_html}
</td>
</tr>
</table>

<p>
{badges_html}
</p>

{extra_html}
</div>"""
    
    return html


def load_catalog() -> Dict:
    """Load the OCI catalog."""
    if CATALOG_PATH.exists():
        with open(CATALOG_PATH) as f:
            return json.load(f)
    return {"apps": {}}


def main():
    """CLI interface for generating descriptions."""
    parser = argparse.ArgumentParser(description="Generate HTML descriptions for Proxmox")
    parser.add_argument("--app-id", help="Application ID from catalog")
    parser.add_argument("--hostname", default="", help="Container hostname")
    parser.add_argument("--extra-info", default="", help="Additional info to display")
    parser.add_argument("--output", choices=["html", "encoded"], default="html",
                        help="Output format: html or url-encoded")
    
    # For VM descriptions (not from catalog)
    parser.add_argument("--vm-name", help="VM name (for non-catalog VMs)")
    parser.add_argument("--vm-version", default="", help="VM version")
    parser.add_argument("--doc-url", default="", help="Documentation URL")
    parser.add_argument("--code-url", default="", help="Code repository URL")
    parser.add_argument("--installer-url", default="", help="Installer URL")
    
    args = parser.parse_args()
    
    if args.app_id:
        # Generate from catalog
        catalog = load_catalog()
        apps = catalog.get("apps", {})
        
        if args.app_id not in apps:
            print(f"Error: App '{args.app_id}' not found in catalog", file=sys.stderr)
            sys.exit(1)
        
        app_def = apps[args.app_id]
        html = generate_description(app_def, hostname=args.hostname, extra_info=args.extra_info)
        
    elif args.vm_name:
        # Generate for VM
        html = generate_vm_description(
            vm_name=args.vm_name,
            vm_version=args.vm_version,
            doc_url=args.doc_url,
            code_url=args.code_url,
            installer_url=args.installer_url,
            extra_info=args.extra_info
        )
    else:
        parser.print_help()
        sys.exit(1)
    
    if args.output == "encoded":
        print(urllib.parse.quote(html))
    else:
        print(html)


if __name__ == "__main__":
    main()
