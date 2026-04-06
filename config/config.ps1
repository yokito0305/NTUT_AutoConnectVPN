# Configuration file for AutoVPN
# This file centralizes all VPN and OpenConnect settings

# === OpenConnect Executable Path ===
# Path to the OpenConnect executable
# Default: Installed in the local bin/ folder by Install-OpenConnect.ps1
# Fallback: C:\Program Files\OpenConnect-GUI\openconnect.exe (if system-wide installation)
$RootDir = if ($PSScriptRoot) { 
    (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath 
} else { 
    (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) '..')).ProviderPath 
}
$BinOpenConnectExe = Join-Path $RootDir 'bin\openconnect.exe'
$SystemOpenConnectExe = "C:\Program Files\OpenConnect-GUI\openconnect.exe"

# Use local bin/ version if exists, otherwise fall back to system-wide installation
$global:Config_OpenConnectExe = if (Test-Path $BinOpenConnectExe) { 
    $BinOpenConnectExe 
} else { 
    $SystemOpenConnectExe 
}

# === VPN Server Configuration ===
# Target VPN server address
# Default: vpn.ntut.edu.tw
$global:Config_VpnServer = "vpn.ntut.edu.tw"

# === VPN Protocol ===
# Protocol to use for VPN connection (e.g., 'gp' for GlobalProtect)
# Default: gp
$global:Config_VpnProtocol = "gp"

# === File Paths ===
# These paths are relative to the project root
# PID file location (tracks running service process)
$global:Config_PidFileName = "vpn_service.pid"

# Log file location (stores connection history and debug info)
$global:Config_LogFileName = "vpn_history.log"

# Raw OpenConnect output log location (stores verbose child stdout/stderr)
$global:Config_OpenConnectRawLogFileName = "vpn_openconnect_raw.log"

# Optional HTTP dump log location (stores dump-http-traffic request/response evidence)
$global:Config_OpenConnectHttpDumpFileName = "vpn_openconnect_http_dump.log"

# Optional HTTP XML/body evidence log location (stores captured XML response bodies when available)
$global:Config_OpenConnectHttpBodyDumpFileName = "vpn_openconnect_http_body_dump.log"

# Credential file location (encrypted VPN credentials)
$global:Config_CredentialFileName = "vpn_cred.xml"

# Runtime state file location (authoritative VPN service/session state for status UI)
$global:Config_VpnStateFileName = "vpn_state.json"

# Stop request sentinel file. Stop_VPN writes this before terminating the
# background service so late supervisor events cannot overwrite the final
# stopped state.
$global:Config_StopRequestFileName = "vpn_stop_requested.flag"

# Replay-derived server configuration cache
$global:Config_ReplayOutputRootName = "out\http-replay"
$global:Config_ReplayCacheFileName = "vpn_config_cache.json"
$global:Config_ReplayCacheTtlHours = 24
$global:Config_ReplayConfigEnabled = $true

# === Reconnection Settings ===
# Delay (in seconds) between reconnection attempts
# Server typically disconnects every 4 hours
$global:Config_ReconnectDelaySeconds = 5

# Retry policy for a previously established VPN session.
# The service will retry in this exact order and then stop.
$global:Config_SessionReconnectDelaysSeconds = @(10, 30)

# Whether to retry the very first connection attempt when no session was established.
$global:Config_RetryInitialConnectFailure = $false

# Whether to retry explicit authentication/setup failures.
$global:Config_RetryAuthFailure = $false

# === OpenConnect Diagnostic Settings ===
# Include verbose logging from OpenConnect. Integer verbosity levels map to:
# 0 = silent/default, 1 = -v, 2 = -vv, 3 = -vvv, 4 = -vvvv
$global:Config_OpenConnectVerbose = 1

# Include OpenConnect-native timestamps in child output
$global:Config_OpenConnectTimestamp = $true

# Reconnect retry timeout in seconds; set to 0 to omit the argument
$global:Config_OpenConnectReconnectTimeoutSeconds = 0

# Force HTTPS-only fallback transport when required by the server/network
$global:Config_OpenConnectNoDtls = $false

# Optional OpenConnect HTTP dump diagnostics; disabled by default because response bodies may contain sensitive config data.
$global:Config_OpenConnectDumpHttpTraffic = $false

# Number of times to queue the VPN password on stdin for OpenConnect. This
# allows GlobalProtect auth flows that consume the initial --passwd-on-stdin
# value and then prompt once more for the same password during form handling.
$global:Config_OpenConnectPasswordStdinRepeatCount = 3

# Relative script paths; resolved from RootDir when queried.
$global:Config_OpenConnectScriptCommand = 'bin\vpnc-script-win.js'
$global:Config_OpenConnectMinimalScriptCommand = 'bin\vpnc-script-win.minimal.js'
$global:Config_OpenConnectUseMinimalScript = $true
$global:Config_OpenConnectScriptDryRun = $false
$global:Config_OpenConnectScriptSkipDns = $false
$global:Config_OpenConnectScriptSkipRoutes = $false
$global:Config_OpenConnectScriptSkipIpv6 = $false

# Supervisor heartbeat interval in seconds
$global:Config_SupervisorHeartbeatSeconds = 60

# === UI / Interactive Output Settings ===
# Controls whether the service opens the foreground review/status window after a
# VPN session is confirmed connected.
$global:Config_ServiceInteractiveOutput = $true

# Controls whether failure notifications open separate interactive popup windows.
# Keep disabled by default so normal startup only shows the post-connect review UI.
$global:Config_ServiceFailureNotifications = $false

# === Process Cleanup ===
# Delay (in seconds) after killing processes to allow full termination
$global:Config_ProcessTerminationDelaySeconds = 3

# === Function to get full paths ===
function Get-VpnConfig {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('PidFile', 'LogFile', 'OpenConnectRawLogFile', 'OpenConnectHttpDumpFile', 'OpenConnectHttpBodyDumpFile', 'CredentialFile', 'StateFile', 'StopRequestFile', 'ReplayOutputRoot', 'ReplayCacheFile', 'ReplayCacheTtlHours', 'ReplayConfigEnabled', 'OpenConnectExe', 'VpnServer', 'VpnProtocol', 'ReconnectDelay', 'ProcessTerminationDelay', 'OpenConnectVerbose', 'OpenConnectTimestamp', 'OpenConnectReconnectTimeoutSeconds', 'OpenConnectNoDtls', 'OpenConnectDumpHttpTraffic', 'OpenConnectPasswordStdinRepeatCount', 'OpenConnectScriptCommand', 'OpenConnectMinimalScriptCommand', 'OpenConnectUseMinimalScript', 'OpenConnectScriptDryRun', 'OpenConnectScriptSkipDns', 'OpenConnectScriptSkipRoutes', 'OpenConnectScriptSkipIpv6', 'SupervisorHeartbeatSeconds', 'SessionReconnectDelays', 'RetryInitialConnectFailure', 'RetryAuthFailure', 'ServiceInteractiveOutput', 'ServiceFailureNotifications')]
        [string] $ConfigKey,
        
        [string] $RootDir  # Optional: project root directory
    )

    # If RootDir not provided, try to determine it
    if (-not $RootDir) {
        $RootDir = if ($PSScriptRoot) { 
            (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath 
        } else { 
            (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) '..')).ProviderPath
        }
    }

    switch ($ConfigKey) {
        'PidFile'                  { return (Join-Path $RootDir $Config_PidFileName) }
        'LogFile'                  { return (Join-Path $RootDir $Config_LogFileName) }
        'OpenConnectRawLogFile'    { return (Join-Path $RootDir $Config_OpenConnectRawLogFileName) }
        'OpenConnectHttpDumpFile'  { return (Join-Path $RootDir $Config_OpenConnectHttpDumpFileName) }
        'OpenConnectHttpBodyDumpFile' { return (Join-Path $RootDir $Config_OpenConnectHttpBodyDumpFileName) }
        'CredentialFile'           { return (Join-Path $RootDir $Config_CredentialFileName) }
        'StateFile'                { return (Join-Path $RootDir $Config_VpnStateFileName) }
        'StopRequestFile'          { return (Join-Path $RootDir $Config_StopRequestFileName) }
        'ReplayOutputRoot'         { return (Join-Path $RootDir $Config_ReplayOutputRootName) }
        'ReplayCacheFile'          { return (Join-Path $RootDir $Config_ReplayCacheFileName) }
        'ReplayCacheTtlHours'      { return $Config_ReplayCacheTtlHours }
        'ReplayConfigEnabled'      { return $Config_ReplayConfigEnabled }
        'OpenConnectExe'           { return $Config_OpenConnectExe }
        'VpnServer'                { return $Config_VpnServer }
        'VpnProtocol'              { return $Config_VpnProtocol }
        'ReconnectDelay'           { return $Config_ReconnectDelaySeconds }
        'SessionReconnectDelays'   { return @($Config_SessionReconnectDelaysSeconds) }
        'RetryInitialConnectFailure' { return $Config_RetryInitialConnectFailure }
        'RetryAuthFailure'         { return $Config_RetryAuthFailure }
        'ProcessTerminationDelay'  { return $Config_ProcessTerminationDelaySeconds }
        'OpenConnectVerbose'       { return $Config_OpenConnectVerbose }
        'OpenConnectTimestamp'     { return $Config_OpenConnectTimestamp }
        'OpenConnectReconnectTimeoutSeconds' { return $Config_OpenConnectReconnectTimeoutSeconds }
        'OpenConnectNoDtls'        { return $Config_OpenConnectNoDtls }
        'OpenConnectDumpHttpTraffic' { return $Config_OpenConnectDumpHttpTraffic }
        'OpenConnectPasswordStdinRepeatCount' { return $Config_OpenConnectPasswordStdinRepeatCount }
        'OpenConnectScriptCommand' {
            $scriptRelativePath = if ($Config_OpenConnectUseMinimalScript) { $Config_OpenConnectMinimalScriptCommand } else { $Config_OpenConnectScriptCommand }
            return (Join-Path $RootDir $scriptRelativePath)
        }
        'OpenConnectMinimalScriptCommand' { return (Join-Path $RootDir $Config_OpenConnectMinimalScriptCommand) }
        'OpenConnectUseMinimalScript' { return $Config_OpenConnectUseMinimalScript }
        'OpenConnectScriptDryRun'  { return $Config_OpenConnectScriptDryRun }
        'OpenConnectScriptSkipDns' { return $Config_OpenConnectScriptSkipDns }
        'OpenConnectScriptSkipRoutes' { return $Config_OpenConnectScriptSkipRoutes }
        'OpenConnectScriptSkipIpv6' { return $Config_OpenConnectScriptSkipIpv6 }
        'SupervisorHeartbeatSeconds' { return $Config_SupervisorHeartbeatSeconds }
        'ServiceInteractiveOutput'  { return $Config_ServiceInteractiveOutput }
        'ServiceFailureNotifications' { return $Config_ServiceFailureNotifications }
        default                    { throw "Unknown configuration key: $ConfigKey" }
    }
}

# === Validation Function ===
function Test-VpnConfig {
    <#
    .SYNOPSIS
    Validates critical VPN configuration settings.
    
    .DESCRIPTION
    Checks that OpenConnect executable exists and VPN server is accessible.
    #>
    
    $errors = @()
    
    # Validate OpenConnect executable
    if (-not (Test-Path $Config_OpenConnectExe)) {
        $errors += "OpenConnect executable not found at: $Config_OpenConnectExe"
    }

    $scriptPath = Get-VpnConfig -ConfigKey 'OpenConnectScriptCommand' -RootDir $RootDir
    if (-not (Test-Path $scriptPath)) {
        $errors += "OpenConnect Windows vpnc-script not found at: $scriptPath"
    }
    
    # Validate VPN server is not empty
    if (-not $Config_VpnServer) {
        $errors += "VPN server address is not configured"
    }
    
    # Validate reconnect delay is positive
    if ($Config_ReconnectDelaySeconds -le 0) {
        $errors += "Reconnect delay must be positive"
    }

    if (-not $Config_SessionReconnectDelaysSeconds -or $Config_SessionReconnectDelaysSeconds.Count -eq 0) {
        $errors += "Session reconnect delays must contain at least one positive delay"
    } elseif (@($Config_SessionReconnectDelaysSeconds | Where-Object { $_ -le 0 }).Count -gt 0) {
        $errors += "Session reconnect delays must be positive integers"
    }

    if ($Config_OpenConnectReconnectTimeoutSeconds -lt 0) {
        $errors += "OpenConnect reconnect timeout cannot be negative"
    }

    if ($Config_SupervisorHeartbeatSeconds -le 0) {
        $errors += "Supervisor heartbeat interval must be positive"
    }

    if ($Config_ReplayCacheTtlHours -le 0) {
        $errors += "Replay cache TTL hours must be positive"
    }
    
    if ($errors.Count -gt 0) {
        Write-Host "Configuration validation failed:" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        return $false
    }
    
    return $true
}
