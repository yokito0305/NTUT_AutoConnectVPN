# 檔案名稱: D:\Program Files\script\src\Stop_VPN_Logic.ps1

# Determine project root (parent of this script's folder) so scripts are relocatable
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RootDir = (Resolve-Path (Join-Path $ScriptRoot '..')).ProviderPath
$WorkDir = $RootDir
$PidFile = Join-Path $WorkDir "vpn_service.pid"
$LogFile = Join-Path $WorkDir "vpn_history.log"

# Ensure Write-Log knows where to write when lib uses env var
$env:LOGFILE = $LogFile

# Record invocation early so we can see whether the elevated process actually ran
try { Write-Log "Stop_VPN invoked via batch" } catch { }

# Load shared library helpers
try {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    $LibPath = Join-Path $ScriptDir 'lib\vpn_common.ps1'
    if (Test-Path $LibPath) { . $LibPath } else { Write-Host "Warning: lib not found: $LibPath" }
} catch {
    Write-Host "Failed to load lib: $_"
}

# 1. 根據 PID 停止背景 PowerShell
if (Test-Path $PidFile) {
    $ServicePid = Get-Content $PidFile
    try {
        Stop-Process -Id $ServicePid -Force -ErrorAction Stop
        Write-Log ("Stopped monitor script (PID: {0}) by Stop_VPN_Logic.ps1" -f $ServicePid)
    } catch {
        Write-Log ("Failed to stop monitor script (PID: {0}): {1}" -f $ServicePid, $_)
    }
    try {
        Remove-Item $PidFile -Force
        Write-Log ("Removed PID file: {0}" -f $PidFile)
    } catch {
        Write-Log ("Failed to remove PID file {0}: {1}" -f $PidFile, $_)
    }
} else {
    Write-Log "Stop requested but PID file not found: $PidFile"
}

# 2. 強制停止 OpenConnect (確保斷線)
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
