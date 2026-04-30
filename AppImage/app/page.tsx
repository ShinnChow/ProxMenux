"use client"

import { useState, useEffect } from "react"
import { ProxmoxDashboard } from "../components/proxmox-dashboard"
import { Login } from "../components/login"
import { AuthSetup } from "../components/auth-setup"
import { getApiUrl } from "../lib/api-config"

export default function Home() {
  const [authStatus, setAuthStatus] = useState<{
    loading: boolean
    authEnabled: boolean
    authConfigured: boolean
    authenticated: boolean
  }>({
    loading: true,
    authEnabled: false,
    authConfigured: false,
    authenticated: false,
  })

  useEffect(() => {
    checkAuthStatus()
  }, [])

  const checkAuthStatus = async () => {
    try {
      const token = localStorage.getItem("proxmenux-auth-token")
      const response = await fetch(getApiUrl("/api/auth/status"), {
        headers: token ? { Authorization: `Bearer ${token}` } : {},
      })
      
      // Check if response is valid JSON before parsing
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`)
      }
      
      const contentType = response.headers.get("content-type")
      if (!contentType || !contentType.includes("application/json")) {
        throw new Error("Response is not JSON")
      }
      
      const data = await response.json()

      const authenticated = data.auth_enabled ? data.authenticated : true

      setAuthStatus({
        loading: false,
        authEnabled: data.auth_enabled,
        authConfigured: data.auth_configured,
        authenticated,
      })
    } catch {
      // API not available - assume no auth configured (silent fail, no console error)
      setAuthStatus({
        loading: false,
        authEnabled: false,
        authConfigured: false,
        authenticated: true,
      })
    }
  }

  const handleAuthComplete = () => {
    checkAuthStatus()
  }

  const handleLoginSuccess = () => {
    checkAuthStatus()
  }

  if (authStatus.loading) {
    return (
      <div className="min-h-screen bg-background flex items-center justify-center">
        <div className="flex flex-col items-center gap-4">
          <div className="relative">
            <div className="h-12 w-12 rounded-full border-2 border-muted"></div>
            <div className="absolute inset-0 h-12 w-12 rounded-full border-2 border-transparent border-t-primary animate-spin"></div>
          </div>
          <div className="text-sm font-medium text-foreground">Loading...</div>
          <p className="text-xs text-muted-foreground">Connecting to ProxMenux Monitor</p>
        </div>
      </div>
    )
  }

  if (authStatus.authEnabled && !authStatus.authenticated) {
    return <Login onLogin={handleLoginSuccess} />
  }

  // Show dashboard in all other cases
  return (
    <>
      {!authStatus.authConfigured && <AuthSetup onComplete={handleAuthComplete} />}
      <ProxmoxDashboard />
    </>
  )
}
