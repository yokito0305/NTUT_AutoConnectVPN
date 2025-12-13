# 檔案名稱: D:\Program Files\script\src\Stop_VPN_Logic.ps1

param(
    [switch] $AlreadyElevated
)

function Test-IsAdministrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Elevation {
    if (Test-IsAdministrator) { return }

    if ($AlreadyElevated) {
        Write-Host "Unable to obtain administrative privileges to stop VPN." -ForegroundColor Red
        exit 1
    }

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-AlreadyElevated')
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $argList
    exit
}

# Elevate once when invoked directly to avoid repeated prompts when chained
if ($MyInvocation.InvocationName -ne '.') {
    Ensure-Elevation
}

# Determine project root (parent of this script's folder) so scripts are relocatable
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RootDir = (Resolve-Path (Join-Path $ScriptRoot '..')).ProviderPath
$WorkDir = $RootDir

# Load configuration
$ConfigPath = Join-Path $RootDir 'config\config.ps1'
if (Test-Path $ConfigPath) {
    . $ConfigPath
} else {
    Write-Host "Error: configuration file not found at $ConfigPath"
    exit 1
}

# Get configuration values
$PidFile = Get-VpnConfig -ConfigKey 'PidFile' -RootDir $RootDir
$LogFile = Get-VpnConfig -ConfigKey 'LogFile' -RootDir $RootDir

# --- Load shared library ---
$env:LOGFILE = $LogFile

$LibPath = Join-Path $ScriptRoot 'lib\vpn_common.ps1'
if (Test-Path $LibPath) {
    . $LibPath
} else {
    Write-Host "Error: lib not found at $LibPath"
    exit 1
}

function Invoke-StopVpnLogic {
    param(
        [string] $PidPath = $PidFile,
        [string] $LogPath = $LogFile
    )

    $env:LOGFILE = $LogPath

    try { Write-Log "Stop_VPN invoked via batch" } catch { }    if (Test-Path $PidPath) {
        $ServicePid = Get-Content $PidPath
        try {
            Stop-Process -Id $ServicePid -Force -ErrorAction Stop
            Write-Log ("Stopped monitor script (PID: {0}) by Stop_VPN_Logic.ps1" -f $ServicePid)
        } catch {
            Write-Log ("Failed to stop monitor script (PID: {0}): {1}" -f $ServicePid, $_)
        }

        try {
            Remove-Item $PidPath -Force
            Write-Log ("Removed PID file: {0}" -f $PidPath)
        } catch {
            Write-Log ("Failed to remove PID file {0}: {1}" -f $PidPath, $_)
        }
    } else {
        Write-Log "Stop requested but PID file not found: $PidPath"
    }

    $oc = Get-Process openconnect -ErrorAction SilentlyContinue
    if ($oc) {
        try {
            $oc | Stop-Process -Force -ErrorAction Stop
            Write-Log (("Stopped OpenConnect processes (count: {0})" -f $($oc.Count)))
        } catch {
            Write-Log (("Failed to stop OpenConnect processes: {0}" -f $_))
        }
    } else {
        Write-Log "No OpenConnect process found to stop."
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-StopVpnLogic
}
