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
    Assert-Elevation
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
$StateFile = Get-VpnConfig -ConfigKey 'StateFile' -RootDir $RootDir
$StopRequestFile = Get-VpnConfig -ConfigKey 'StopRequestFile' -RootDir $RootDir

# --- Load shared library ---
$env:LOGFILE = $LogFile

$LibPath = Join-Path $ScriptRoot 'lib\vpn_common.ps1'
if (Test-Path $LibPath) {
    . $LibPath
} else {
    Write-Host "Error: lib not found at $LibPath"
    exit 1
}

foreach ($modulePath in @(
    (Join-Path $ScriptRoot 'lib\network_config_models.ps1'),
    (Join-Path $ScriptRoot 'lib\network_config.ps1')
)) {
    if (-not (Test-Path $modulePath)) {
        Write-Host "Error: module not found at $modulePath"
        exit 1
    }

    . $modulePath
}

function Invoke-StopVpnLogic {
    param(
        [string] $PidPath = $PidFile,
        [string] $LogPath = $LogFile,
        [string] $StatePath = $StateFile,
        [string] $StopRequestPath = $StopRequestFile
    )

    $env:LOGFILE = $LogPath
    $existingState = Read-VpnRuntimeState -StatePath $StatePath

    try {
        Write-LogEvent -Segments @('service', 'stop') -Message 'Stop_VPN invoked via batch' -LogPath $LogPath
    } catch {
    }

    Set-VpnStopRequest -RequestPath $StopRequestPath

    if (Test-Path $PidPath) {
        $ServicePid = Get-Content $PidPath -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ServicePid) {
            try {
                Stop-Process -Id $ServicePid -Force -ErrorAction Stop
                Write-LogEvent -Segments @('service', 'stop') -Message ("Stopped monitor script (PID: {0}) by Stop_VPN_Logic.ps1" -f $ServicePid) -LogPath $LogPath
            } catch {
                Write-LogEvent -Segments @('service', 'stop') -Message ("Failed to stop monitor script (PID: {0}): {1}" -f $ServicePid, $_) -LogPath $LogPath
            }
        } else {
            Write-LogEvent -Segments @('service', 'stop') -Message ("PID file was empty or unreadable: {0}" -f $PidPath) -LogPath $LogPath
        }

        try {
            Remove-Item $PidPath -Force
            Write-LogEvent -Segments @('service', 'stop') -Message ("Removed PID file: {0}" -f $PidPath) -LogPath $LogPath
        } catch {
            Write-LogEvent -Segments @('service', 'stop') -Message ("Failed to remove PID file {0}: {1}" -f $PidPath, $_) -LogPath $LogPath
        }
    } else {
        Write-LogEvent -Segments @('service', 'stop') -Message "Stop requested but PID file not found: $PidPath" -LogPath $LogPath
    }

    $oc = Get-Process openconnect -ErrorAction SilentlyContinue
    if ($oc) {
        try {
            $oc | Stop-Process -Force -ErrorAction Stop
            Write-LogEvent -Segments @('openconnect', 'stop') -Message (("Stopped OpenConnect processes (count: {0})" -f $($oc.Count))) -LogPath $LogPath
        } catch {
            Write-LogEvent -Segments @('openconnect', 'stop') -Message (("Failed to stop OpenConnect processes: {0}" -f $_)) -LogPath $LogPath
        }
    } else {
        Write-LogEvent -Segments @('openconnect', 'stop') -Message 'No OpenConnect process found to stop.' -LogPath $LogPath
    }

    if ($existingState -and $existingState.network_config_plan) {
        try {
            $routeReverted = Invoke-NetworkConfigurationRouteRevert -Plan $existingState.network_config_plan -LogPath $LogPath
            if (-not $routeReverted) {
                Write-LogEvent -Segments @('network-config', 'route-revert') -Message 'No owned route changes required rollback.' -LogPath $LogPath
            }
        } catch {
            Write-LogEvent -Segments @('network-config', 'route-revert') -Message ("Failed to revert owned routes: {0}" -f $_) -LogPath $LogPath
        }

        try {
            $dnsReverted = Invoke-NetworkConfigurationDnsRevert -Plan $existingState.network_config_plan -LogPath $LogPath
            if (-not $dnsReverted) {
                Write-LogEvent -Segments @('network-config', 'dns-revert') -Message 'No owned adapter-scoped DNS changes required rollback.' -LogPath $LogPath
            }
        } catch {
            Write-LogEvent -Segments @('network-config', 'dns-revert') -Message ("Failed to revert adapter-scoped DNS: {0}" -f $_) -LogPath $LogPath
        }
    }

    Write-VpnRuntimeState -StatePath $StatePath -ServiceState 'stopped' -SessionState 'stopped' -Reason 'Startup protection cleared by Stop_VPN.bat.' -ServicePid 0 -OpenConnectPid 0 -ConnectedAt $null -StartupBlocked $false -StartupBlockCategory $null
    Write-LogEvent -Segments @('service', 'guard') -Message 'Cleared protective startup block and reset runtime state.' -LogPath $LogPath
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-StopVpnLogic
}
