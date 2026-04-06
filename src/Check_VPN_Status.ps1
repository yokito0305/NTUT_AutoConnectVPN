# File: D:\Program Files\script\src\Check_VPN_Status.ps1

# --- Configuration ---
# Determine project root
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RootDir = (Resolve-Path (Join-Path $ScriptRoot '..')).ProviderPath

# Load configuration
$ConfigPath = Join-Path $RootDir 'config\config.ps1'
if (Test-Path $ConfigPath) {
    . $ConfigPath
}

$LibPath = Join-Path $ScriptRoot 'lib\vpn_common.ps1'
if (Test-Path $LibPath) {
    . $LibPath
}

function ConvertTo-NullableDateTime {
    param(
        [AllowNull()] [object] $Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string] $Value)) {
        return $null
    }

    try {
        return [datetime]::Parse([string] $Value)
    } catch {
        return $null
    }
}

function Get-VpnStatusModel {
    param(
        [string] $StatePath = (Get-VpnConfig -ConfigKey 'StateFile' -RootDir $RootDir)
    )

    $state = Read-VpnRuntimeState -StatePath $StatePath
    if (-not $state) {
        return [PSCustomObject]@{
            SessionState = 'stopped'
            ServiceState = 'stopped'
            Reason = 'No VPN service state file was found.'
            OpenConnectPid = $null
            ConnectedAt = $null
        }
    }

    $connectedAt = ConvertTo-NullableDateTime -Value $state.connected_at
    $sessionExpiresAt = ConvertTo-NullableDateTime -Value $state.session_expires_at
    $transportChangedAt = ConvertTo-NullableDateTime -Value $state.transport_changed_at
    $lastTransportEventAt = ConvertTo-NullableDateTime -Value $state.last_transport_event_at
    $lastRekeyAt = ConvertTo-NullableDateTime -Value $state.last_rekey_at
    $lastHipCheckAt = ConvertTo-NullableDateTime -Value $state.last_hip_check_at
    $lastDpdOkAt = ConvertTo-NullableDateTime -Value $state.last_dpd_ok_at

    $planAssignedIp = $null
    $planGateway = $null
    if ($state.network_config_plan) {
        if ($state.network_config_plan.AssignedIp) {
            $planAssignedIp = [string] $state.network_config_plan.AssignedIp
        }
        if ($state.network_config_plan.Gateway) {
            $planGateway = [string] $state.network_config_plan.Gateway
        }
    }

    return [PSCustomObject]@{
        SessionState = $state.session_state
        ServiceState = $state.service_state
        Reason = $state.reason
        StartupBlocked = [bool] $state.startup_blocked
        StartupBlockCategory = $state.startup_block_category
        OpenConnectPid = $state.openconnect_pid
        ConnectedAt = $connectedAt
        AssignedIp = if ($state.assigned_ip) { $state.assigned_ip } else { $planAssignedIp }
        SessionExpiresAt = $sessionExpiresAt
        Gateway = if ($state.gateway) { $state.gateway } else { $planGateway }
        TransportMode = $state.transport_mode
        TransportChangedAt = $transportChangedAt
        LastTransportEvent = $state.last_transport_event
        LastTransportEventAt = $lastTransportEventAt
        LastRekeyAt = $lastRekeyAt
        LastHipCheckAt = $lastHipCheckAt
        LastDpdOkAt = $lastDpdOkAt
    }
}

function Show-VpnStatus {
    param(
        [string] $StatePath = (Get-VpnConfig -ConfigKey 'StateFile' -RootDir $RootDir)
    )

    Clear-Host
    Write-Host "=== VPN Background Service Status Check ===" -ForegroundColor Cyan
    Write-Host "--------------------------------"

    $status = Get-VpnStatusModel -StatePath $StatePath
    if ($status.StartupBlocked) {
        Write-Host "[VPN Connection]" -NoNewline
        Write-Host " ! Blocked" -ForegroundColor Red
        if ($status.Reason) {
            Write-Host "       Reason: $($status.Reason)"
        }
        if ($status.StartupBlockCategory) {
            Write-Host "       Unlock required: run Stop_VPN.bat before the next start attempt."
        }
    } elseif ($status.SessionState -eq 'connected') {
        Write-Host "[VPN Connection]" -NoNewline
        if ($status.OpenConnectPid) {
            Write-Host " * Connected (PID: $($status.OpenConnectPid))" -ForegroundColor Green
        } else {
            Write-Host " * Connected" -ForegroundColor Green
        }

        if ($status.ConnectedAt) {
            $Duration = (Get-Date) - $status.ConnectedAt
            $TimeStr = "{0:hh}h {0:mm}m {0:ss}s" -f $Duration
            Write-Host "       Connection duration: $TimeStr"
        } else {
            Write-Host "       Connection duration: unknown"
        }
        if ($status.AssignedIp) {
            Write-Host "       Assigned IP: $($status.AssignedIp)"
        }
        if ($status.Gateway) {
            Write-Host "       Gateway: $($status.Gateway)"
        }
        if ($status.SessionExpiresAt) {
            Write-Host "       Session expires at: $($status.SessionExpiresAt)"
        }
        if ($status.TransportMode) {
            $transportLabel = if ($status.TransportMode -eq 'https_fallback') { 'HTTPS fallback (degraded)' } else { $status.TransportMode }
            Write-Host "       Transport mode: $transportLabel"
        }
        if ($status.LastTransportEvent) {
            Write-Host "       Last transport event: $($status.LastTransportEvent)"
        }
        if ($status.TransportChangedAt) {
            Write-Host "       Transport changed at: $($status.TransportChangedAt)"
        }
        if ($status.LastRekeyAt) {
            Write-Host "       Last rekey: $($status.LastRekeyAt)"
        }
        if ($status.LastHipCheckAt) {
            Write-Host "       Last HIP check: $($status.LastHipCheckAt)"
        }
        if ($status.LastDpdOkAt) {
            Write-Host "       Last DPD OK: $($status.LastDpdOkAt)"
        }
    } elseif ($status.SessionState -eq 'authenticating' -or $status.SessionState -eq 'launching' -or $status.ServiceState -eq 'reconnecting' -or $status.ServiceState -eq 'starting') {
        Write-Host "[VPN Connection]" -NoNewline
        Write-Host " ~ Connecting" -ForegroundColor Yellow
        if ($status.Reason) {
            Write-Host "       Last event: $($status.Reason)"
        }
    } else {
        Write-Host "[VPN Connection]" -NoNewline
        Write-Host " o Disconnected" -ForegroundColor Red
        if ($status.Reason) {
            Write-Host "       Reason: $($status.Reason)"
        }
    }

    Write-Host ""
}

if ($MyInvocation.InvocationName -ne '.') {
    Show-VpnStatus
}
