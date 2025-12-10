# 檔案名稱: D:\Program Files\script\src\Stop_VPN_Logic.ps1

# Determine project root (parent of this script's folder) so scripts are relocatable
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RootDir = (Resolve-Path (Join-Path $ScriptRoot '..')).ProviderPath
$WorkDir = $RootDir
$PidFile = Join-Path $WorkDir "vpn_service.pid"
$LogFile = Join-Path $WorkDir "vpn_history.log"

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

    try { Write-Log "Stop_VPN invoked via batch" } catch { }

    if (Test-Path $PidPath) {
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
