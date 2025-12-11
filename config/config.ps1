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

# Credential file location (encrypted VPN credentials)
$global:Config_CredentialFileName = "vpn_cred.xml"

# === Reconnection Settings ===
# Delay (in seconds) between reconnection attempts
# Server typically disconnects every 4 hours
$global:Config_ReconnectDelaySeconds = 10

# === Process Cleanup ===
# Delay (in seconds) after killing processes to allow full termination
$global:Config_ProcessTerminationDelaySeconds = 2

# === Function to get full paths ===
function Get-VpnConfig {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('PidFile', 'LogFile', 'CredentialFile', 'OpenConnectExe', 'VpnServer', 'VpnProtocol', 'ReconnectDelay', 'ProcessTerminationDelay')]
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
        'CredentialFile'           { return (Join-Path $RootDir $Config_CredentialFileName) }
        'OpenConnectExe'           { return $Config_OpenConnectExe }
        'VpnServer'                { return $Config_VpnServer }
        'VpnProtocol'              { return $Config_VpnProtocol }
        'ReconnectDelay'           { return $Config_ReconnectDelaySeconds }
        'ProcessTerminationDelay'  { return $Config_ProcessTerminationDelaySeconds }
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
    
    # Validate VPN server is not empty
    if (-not $Config_VpnServer) {
        $errors += "VPN server address is not configured"
    }
    
    # Validate reconnect delay is positive
    if ($Config_ReconnectDelaySeconds -le 0) {
        $errors += "Reconnect delay must be positive"
    }
    
    if ($errors.Count -gt 0) {
        Write-Host "Configuration validation failed:" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        return $false
    }
    
    return $true
}
