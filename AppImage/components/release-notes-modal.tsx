"use client"

import { useState, useEffect } from "react"
import { Button } from "./ui/button"
import { Dialog, DialogContent, DialogTitle } from "./ui/dialog"
import { X, Sparkles, Thermometer, Terminal, Activity, HardDrive, Bell, Shield, Globe, Cpu, Zap } from "lucide-react"
import { Checkbox } from "./ui/checkbox"

const APP_VERSION = "1.2.0" // Sync with AppImage/package.json

interface ReleaseNote {
  date: string
  changes: {
    added?: string[]
    changed?: string[]
    fixed?: string[]
  }
}

export const CHANGELOG: Record<string, ReleaseNote> = {
  "1.1.2-beta": {
    date: "March 18, 2026",
    changes: {
      added: [
        "Temperature & Latency Charts - Real-time visual monitoring with interactive graphs",
        "WebSocket Terminal - Direct access to Proxmox host and LXC containers terminal",
        "AI-Enhanced Notifications - Intelligent message formatting with multi-provider support (OpenAI, Groq, Anthropic, Ollama)",
        "Security Section - Comprehensive security settings for ProxMenux and Proxmox",
        "VPN Integration - Easy Tailscale VPN installation and configuration",
        "GPU Scripts - Installation utilities for Intel, AMD and NVIDIA drivers",
        "Disk Observations System - Track and document disk health observations over time",
        "Enhanced Health Monitor - Configurable monitoring with advanced settings panel",
      ],
      changed: [
        "Improved overall performance with optimized data fetching",
        "Notifications now support rich formatting with contextual emojis",
        "Health monitor now configurable from Settings section",
        "Better Proxmox service name translation for non-expert users",
      ],
      fixed: [
        "Fixed notification message truncation for large backup reports",
        "Improved disk error deduplication to prevent repeated alerts",
        "Corrected AI provider base URL handling for OpenAI-compatible APIs",
      ],
    },
  },
  "1.0.1": {
    date: "November 11, 2025",
    changes: {
      added: [
        "Proxy Support - Access ProxMenux through reverse proxies with full functionality",
        "Authentication System - Secure your dashboard with password protection",
        "PCIe Link Speed Detection - View NVMe drive connection speeds and detect performance issues",
        "Two-Factor Authentication (2FA) - Enhanced security with TOTP support",
        "Health Monitoring System - Comprehensive system health checks with dismissible warnings",
      ],
      changed: [
        "Optimized VM & LXC page - Reduced CPU usage by 85% through intelligent caching",
        "Storage metrics now separate local and remote storage for clarity",
      ],
      fixed: [
        "Fixed dark mode text contrast issues in various components",
        "Corrected storage calculation discrepancies between Overview and Storage pages",
      ],
    },
  },
  "1.0.0": {
    date: "October 15, 2025",
    changes: {
      added: [
        "Initial release of ProxMenux Monitor",
        "Real-time system monitoring dashboard",
        "Storage management with SMART health monitoring",
        "Network metrics and bandwidth tracking",
        "VM & LXC container management",
        "Hardware information display",
        "System logs viewer with filtering",
      ],
    },
  },
}

const CURRENT_VERSION_FEATURES = [
  {
    icon: <Thermometer className="h-5 w-5" />,
    text: "Temperature & Latency Charts - Real-time visual monitoring with interactive historical graphs",
  },
  {
    icon: <Terminal className="h-5 w-5" />,
    text: "WebSocket Terminal - Direct terminal access to Proxmox host and LXC containers from the browser",
  },
  {
    icon: <Activity className="h-5 w-5" />,
    text: "Enhanced Health Monitor - Configurable health monitoring with advanced settings and disk observations",
  },
  {
    icon: <Bell className="h-5 w-5" />,
    text: "AI-Enhanced Notifications - Intelligent message formatting with support for OpenAI, Groq, Anthropic and Ollama",
  },
  {
    icon: <Shield className="h-5 w-5" />,
    text: "Security Section - Comprehensive security configuration for both ProxMenux and Proxmox systems",
  },
  {
    icon: <Globe className="h-5 w-5" />,
    text: "VPN Integration - Easy Tailscale VPN installation and configuration for secure remote access",
  },
  {
    icon: <Cpu className="h-5 w-5" />,
    text: "GPU Drivers - Installation scripts for Intel, AMD and NVIDIA graphics drivers and utilities",
  },
  {
    icon: <Zap className="h-5 w-5" />,
    text: "Performance Improvements - Optimized data fetching and reduced resource consumption",
  },
]

interface ReleaseNotesModalProps {
  open: boolean
  onClose: () => void
}

export function ReleaseNotesModal({ open, onClose }: ReleaseNotesModalProps) {
  const [dontShowAgain, setDontShowAgain] = useState(false)

  const handleClose = () => {
    if (dontShowAgain) {
      localStorage.setItem("proxmenux-last-seen-version", APP_VERSION)
    }
    onClose()
  }

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="max-w-2xl max-h-[85vh] p-0 gap-0 border-0 bg-transparent">
        <DialogTitle className="sr-only">Release Notes - Version {APP_VERSION}</DialogTitle>
        <div className="relative bg-card rounded-lg shadow-2xl h-full flex flex-col max-h-[85vh]">
          <Button
            variant="ghost"
            size="icon"
            className="absolute top-4 right-4 z-50 h-8 w-8 rounded-full bg-background/80 backdrop-blur-sm hover:bg-background"
            onClick={handleClose}
          >
            <X className="h-4 w-4" />
          </Button>

          <div className="relative h-32 md:h-40 bg-gradient-to-br from-amber-500 via-orange-500 to-red-500 flex items-center justify-center overflow-hidden flex-shrink-0">
            <div className="absolute inset-0 bg-black/10" />
            <div className="absolute inset-0 bg-[radial-gradient(circle_at_50%_120%,rgba(255,255,255,0.1),transparent)]" />

            <div className="relative z-10 text-white animate-pulse">
              <Sparkles className="h-12 w-12 md:h-14 md:w-14" />
            </div>

            <div className="absolute top-10 left-10 w-20 h-20 bg-white/10 rounded-full blur-2xl" />
            <div className="absolute bottom-10 right-10 w-32 h-32 bg-white/10 rounded-full blur-3xl" />
          </div>

          <div className="flex-1 overflow-y-auto p-6 md:p-8 space-y-4 md:space-y-6 min-h-0">
            <div className="space-y-2">
              <h2 className="text-xl md:text-2xl font-bold text-foreground text-balance">
                What's New in Version {APP_VERSION}
              </h2>
              <p className="text-sm text-muted-foreground leading-relaxed">
                We've added exciting new features and improvements to make ProxMenux Monitor even better!
              </p>
            </div>

            <div className="space-y-2">
              {CURRENT_VERSION_FEATURES.map((feature, index) => (
                <div
                  key={index}
                  className="flex items-start gap-2 md:gap-3 p-3 rounded-lg bg-muted/50 border border-border/50 hover:bg-muted/70 transition-colors"
                >
                  <div className="text-orange-500 mt-0.5 flex-shrink-0">{feature.icon}</div>
                  <p className="text-xs md:text-sm text-foreground leading-relaxed">{feature.text}</p>
                </div>
              ))}
            </div>
          </div>

          <div className="flex-shrink-0 p-6 md:p-8 pt-4 border-t border-border/50 bg-card">
            <div className="flex flex-col gap-3">
              <Button
                onClick={handleClose}
                className="w-full bg-gradient-to-r from-amber-500 to-orange-500 hover:from-amber-600 hover:to-orange-600"
              >
                <Sparkles className="h-4 w-4 mr-2" />
                Got it!
              </Button>

              <div className="flex items-center justify-center gap-2">
                <Checkbox
                  id="dont-show-version-again"
                  checked={dontShowAgain}
                  onCheckedChange={(checked) => setDontShowAgain(checked as boolean)}
                />
                <label
                  htmlFor="dont-show-version-again"
                  className="text-xs md:text-sm text-muted-foreground hover:text-foreground transition-colors cursor-pointer select-none"
                >
                  Don't show again for this version
                </label>
              </div>
            </div>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  )
}

export function useVersionCheck() {
  const [showReleaseNotes, setShowReleaseNotes] = useState(false)

  useEffect(() => {
    const lastSeenVersion = localStorage.getItem("proxmenux-last-seen-version")

    if (lastSeenVersion !== APP_VERSION) {
      setShowReleaseNotes(true)
    }
  }, [])

  return { showReleaseNotes, setShowReleaseNotes }
}

export { APP_VERSION }
