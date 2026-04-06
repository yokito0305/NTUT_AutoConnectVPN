# Original location: D:\Program Files\script\src\AutoVPN_Service.ps1

param(
    [switch] $AlreadyElevated
)

function Test-IsAdministrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Elevation {
    param(
        [switch] $HiddenWindow
    )

    if (Test-IsAdministrator) { return }

    if ($AlreadyElevated) {
        Write-Host "Elevation requested but administrative privileges were not granted." -ForegroundColor Red
        exit 1
    }

    $windowStyle = if ($HiddenWindow) { 'Hidden' } else { 'Normal' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-AlreadyElevated')
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle $windowStyle -ArgumentList $argList
    exit
}

# Elevate once when launched directly; keep background hidden by default
if ($MyInvocation.InvocationName -ne '.') {
    Ensure-Elevation -HiddenWindow
}

# --- Configuration ---
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RootDir = (Resolve-Path (Join-Path $ScriptRoot '..')).ProviderPath
$WorkDir = $RootDir

$ConfigPath = Join-Path $RootDir 'config\config.ps1'
if (Test-Path $ConfigPath) {
    . $ConfigPath
} else {
    Write-Host "Error: configuration file not found at $ConfigPath"
    exit 1
}

$OpenConnectExe = Get-VpnConfig -ConfigKey 'OpenConnectExe' -RootDir $RootDir
$Server = Get-VpnConfig -ConfigKey 'VpnServer' -RootDir $RootDir
$PidFile = Get-VpnConfig -ConfigKey 'PidFile' -RootDir $RootDir
$LogFile = Get-VpnConfig -ConfigKey 'LogFile' -RootDir $RootDir
$OpenConnectRawLogFile = Get-VpnConfig -ConfigKey 'OpenConnectRawLogFile' -RootDir $RootDir
$OpenConnectHttpDumpFile = Get-VpnConfig -ConfigKey 'OpenConnectHttpDumpFile' -RootDir $RootDir
$OpenConnectHttpBodyDumpFile = Get-VpnConfig -ConfigKey 'OpenConnectHttpBodyDumpFile' -RootDir $RootDir
$StateFile = Get-VpnConfig -ConfigKey 'StateFile' -RootDir $RootDir
$StopRequestFile = Get-VpnConfig -ConfigKey 'StopRequestFile' -RootDir $RootDir
$Protocol = Get-VpnConfig -ConfigKey 'VpnProtocol' -RootDir $RootDir

if (-not (Test-VpnConfig)) {
    exit 1
}

$env:LOGFILE = $LogFile

$LibPath = Join-Path $ScriptRoot 'lib\vpn_common.ps1'
if (Test-Path $LibPath) {
    . $LibPath
} else {
    Write-Host "Error: lib not found at $LibPath"
    exit 1
}

function Invoke-CredentialSetup {
    param([Parameter(Mandatory = $true)] [string] $SetupScript)

    if (-not (Test-Path $SetupScript)) {
        Write-LogEvent -Segments @('credential', 'setup') -Message ("Credential setup script missing: {0}" -f $SetupScript) -LogPath $LogFile
        Write-Host "Credential setup script not found: $SetupScript" -ForegroundColor Red
        exit
    }

    Write-LogEvent -Segments @('credential', 'setup') -Message ("Launching credential setup: {0}" -f $SetupScript) -LogPath $LogFile
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$SetupScript`"" -Wait -WindowStyle Normal
}

function Load-Credential {
    param([Parameter(Mandatory = $true)] [string[]] $Candidates)

    $credPath = $Candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $credPath) { return $null }

    try {
        $cred = Import-Clixml -Path $credPath
        if ($cred -is [System.Management.Automation.PSCredential]) {
            return @{ Path = $credPath; Credential = $cred }
        }

        Write-LogEvent -Segments @('credential', 'load') -Message 'Imported credential was not a PSCredential object.' -LogPath $LogFile
    } catch {
        Write-LogEvent -Segments @('credential', 'load') -Message ("Failed to import credential file {0}: {1}" -f $credPath, $_) -LogPath $LogFile
    }

    return $null
}

function Get-CredentialData {
    param(
        [Parameter(Mandatory = $true)] [string[]] $Candidates,
        [Parameter(Mandatory = $true)] [string] $SetupScript
    )

    $credData = Load-Credential -Candidates $Candidates
    if ($credData) { return $credData }

    Write-LogEvent -Segments @('credential', 'load') -Message 'No valid credential found. Triggering interactive setup.' -LogPath $LogFile
    Invoke-CredentialSetup -SetupScript $SetupScript
    return (Load-Credential -Candidates $Candidates)
}

function Set-WorkingContext {
    param(
        [string] $PidPath = $PidFile,
        [string] $WorkingDirectory = $WorkDir
    )

    $PID | Out-File -FilePath $PidPath -Force
    Set-Location $WorkingDirectory
}

function Show-StatusWindow {
    param([string] $StatusScript)

    if (-not (Get-VpnConfig -ConfigKey 'ServiceInteractiveOutput' -RootDir $RootDir)) {
        return
    }

    if (Test-Path $StatusScript) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',"`"$StatusScript`"" -WindowStyle Normal
    }
}

function Show-TerminalStatusWindow {
    param(
        [string] $StatusScript,
        [int] $ExitCode,
        [string] $ShutdownReason
    )

    if ($ExitCode -eq 0) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($ShutdownReason) -or $ShutdownReason -eq 'Requested shutdown') {
        return
    }

    Show-StatusWindow -StatusScript $StatusScript
}

function ConvertTo-EncodedPowerShellCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Command
    )

    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
}

function New-ServiceNotificationScript {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Title,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    $escapedTitle = $Title -replace "'", "''"
    $escapedMessage = $Message -replace "'", "''"

    return @'
$host.UI.RawUI.WindowTitle = '{0}'
Write-Host '{0}' -ForegroundColor Yellow
Write-Host ''
Write-Host '{1}'
Write-Host ''
Read-Host 'Press Enter to close'
'@ -f $escapedTitle, $escapedMessage
}

function Show-ServiceNotification {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Title,

        [Parameter(Mandatory = $true)]
        [string] $Message,

        [string] $LogPath = $LogFile
    )

    Write-LogEvent -Segments @('service', 'notify') -Message ('{0}: {1}' -f $Title, $Message) -LogPath $LogPath

    if (-not (Get-VpnConfig -ConfigKey 'ServiceFailureNotifications' -RootDir $RootDir)) {
        return
    }

    $notificationScript = New-ServiceNotificationScript -Title $Title -Message $Message
    $encodedCommand = ConvertTo-EncodedPowerShellCommand -Command $notificationScript
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand -WindowStyle Normal
}

function Update-ServiceRuntimeState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ServiceState,

        [Parameter(Mandatory = $true)]
        [string] $SessionState,

        [string] $Reason,

        [int] $OpenConnectPid,

        [AllowNull()] [Nullable[datetime]] $ConnectedAt,

        [AllowNull()] [Nullable[bool]] $StartupBlocked = $null,

        [string] $StartupBlockCategory,

        [string] $AssignedIp,

        [AllowNull()] [Nullable[datetime]] $SessionExpiresAt,

        [string] $Gateway,

        [string] $TransportMode,

        [AllowNull()] [Nullable[datetime]] $TransportChangedAt,

        [string] $LastTransportEvent,

        [AllowNull()] [Nullable[datetime]] $LastTransportEventAt,

        [AllowNull()] [Nullable[datetime]] $LastRekeyAt,

        [AllowNull()] [Nullable[datetime]] $LastHipCheckAt,

        [AllowNull()] [Nullable[datetime]] $LastDpdOkAt,

        [string] $NetworkConfigStatus,

        [string] $NetworkConfigSource,

        [string] $NetworkConfigError,

        [AllowNull()] [Nullable[datetime]] $NetworkConfigLastUpdated,

        [psobject] $NetworkConfigPlan,

        [object[]] $NetworkConflicts,

        [AllowNull()] [Nullable[datetime]] $LastDisconnectAt,

        [string] $LastDisconnectReason,

        [string] $LastDisconnectClassification,

        [string] $LastDisconnectEvidence,

        [int] $LastDisconnectPid,

        [AllowNull()] [Nullable[double]] $LastDisconnectSessionAgeSeconds,

        [AllowNull()] [Nullable[datetime]] $LastFullReconnectAt,

        [int] $ReconnectCount,

        [AllowNull()] [Nullable[datetime]] $PredictedSessionExpiryAt,

        [AllowNull()] [Nullable[datetime]] $PlannedReconnectAt,

        [string] $PlannedReconnectReason
    )

    $stopRequested = Test-VpnStopRequest -RequestPath $StopRequestFile
    if ($stopRequested -and $ServiceState -ne 'stopped' -and $ServiceState -ne 'blocked') {
        return
    }

    $currentState = Read-VpnRuntimeState -StatePath $StateFile
    $effectiveStartupBlocked = if ($null -ne $StartupBlocked) {
        [bool] $StartupBlocked
    } elseif ($currentState) {
        [bool] $currentState.startup_blocked
    } else {
        $false
    }

    $effectiveStartupBlockCategory = if ($PSBoundParameters.ContainsKey('StartupBlockCategory')) {
        $StartupBlockCategory
    } elseif ($effectiveStartupBlocked -and $currentState) {
        [string] $currentState.startup_block_category
    } else {
        $null
    }

    $effectiveAssignedIp = if ($PSBoundParameters.ContainsKey('AssignedIp')) {
        $AssignedIp
    } elseif ($currentState) {
        [string] $currentState.assigned_ip
    } else {
        $null
    }

    $effectiveSessionExpiresAt = if ($PSBoundParameters.ContainsKey('SessionExpiresAt')) {
        $SessionExpiresAt
    } elseif ($currentState -and $currentState.session_expires_at) {
        try {
            [datetime]::Parse($currentState.session_expires_at)
        } catch {
            $null
        }
    } else {
        $null
    }

    $effectiveGateway = if ($PSBoundParameters.ContainsKey('Gateway')) {
        $Gateway
    } elseif ($currentState) {
        [string] $currentState.gateway
    } else {
        $null
    }

    $effectiveTransportMode = if ($PSBoundParameters.ContainsKey('TransportMode')) {
        $TransportMode
    } elseif ($currentState) {
        [string] $currentState.transport_mode
    } else {
        $null
    }

    $effectiveTransportChangedAt = if ($PSBoundParameters.ContainsKey('TransportChangedAt')) {
        $TransportChangedAt
    } elseif ($currentState -and $currentState.transport_changed_at) {
        try { [datetime]::Parse($currentState.transport_changed_at) } catch { $null }
    } else {
        $null
    }

    $effectiveLastTransportEvent = if ($PSBoundParameters.ContainsKey('LastTransportEvent')) {
        $LastTransportEvent
    } elseif ($currentState) {
        [string] $currentState.last_transport_event
    } else {
        $null
    }

    $effectiveLastTransportEventAt = if ($PSBoundParameters.ContainsKey('LastTransportEventAt')) {
        $LastTransportEventAt
    } elseif ($currentState -and $currentState.last_transport_event_at) {
        try { [datetime]::Parse($currentState.last_transport_event_at) } catch { $null }
    } else {
        $null
    }

    $effectiveLastRekeyAt = if ($PSBoundParameters.ContainsKey('LastRekeyAt')) {
        $LastRekeyAt
    } elseif ($currentState -and $currentState.last_rekey_at) {
        try { [datetime]::Parse($currentState.last_rekey_at) } catch { $null }
    } else {
        $null
    }

    $effectiveLastHipCheckAt = if ($PSBoundParameters.ContainsKey('LastHipCheckAt')) {
        $LastHipCheckAt
    } elseif ($currentState -and $currentState.last_hip_check_at) {
        try { [datetime]::Parse($currentState.last_hip_check_at) } catch { $null }
    } else {
        $null
    }

    $effectiveLastDpdOkAt = if ($PSBoundParameters.ContainsKey('LastDpdOkAt')) {
        $LastDpdOkAt
    } elseif ($currentState -and $currentState.last_dpd_ok_at) {
        try { [datetime]::Parse($currentState.last_dpd_ok_at) } catch { $null }
    } else {
        $null
    }

    $effectiveNetworkConfigStatus = if ($PSBoundParameters.ContainsKey('NetworkConfigStatus')) {
        $NetworkConfigStatus
    } elseif ($currentState) {
        [string] $currentState.network_config_status
    } else {
        $null
    }

    $effectiveNetworkConfigSource = if ($PSBoundParameters.ContainsKey('NetworkConfigSource')) {
        $NetworkConfigSource
    } elseif ($currentState) {
        [string] $currentState.network_config_source
    } else {
        $null
    }

    $effectiveNetworkConfigError = if ($PSBoundParameters.ContainsKey('NetworkConfigError')) {
        $NetworkConfigError
    } elseif ($currentState) {
        [string] $currentState.network_config_error
    } else {
        $null
    }

    $effectiveNetworkConfigLastUpdated = if ($PSBoundParameters.ContainsKey('NetworkConfigLastUpdated')) {
        $NetworkConfigLastUpdated
    } elseif ($currentState -and $currentState.network_config_last_updated) {
        try { [datetime]::Parse($currentState.network_config_last_updated) } catch { $null }
    } else {
        $null
    }

    $effectiveNetworkConfigPlan = if ($PSBoundParameters.ContainsKey('NetworkConfigPlan')) {
        $NetworkConfigPlan
    } elseif ($currentState) {
        $currentState.network_config_plan
    } else {
        $null
    }

    if ([string]::IsNullOrWhiteSpace($effectiveAssignedIp) -and $effectiveNetworkConfigPlan -and $effectiveNetworkConfigPlan.AssignedIp) {
        $effectiveAssignedIp = [string] $effectiveNetworkConfigPlan.AssignedIp
    }

    if ([string]::IsNullOrWhiteSpace($effectiveGateway) -and $effectiveNetworkConfigPlan -and $effectiveNetworkConfigPlan.Gateway) {
        $effectiveGateway = [string] $effectiveNetworkConfigPlan.Gateway
    }

    $effectiveNetworkConflicts = if ($PSBoundParameters.ContainsKey('NetworkConflicts')) {
        @($NetworkConflicts)
    } elseif ($currentState -and $null -ne $currentState.network_conflicts) {
        @($currentState.network_conflicts)
    } else {
        @()
    }

    $effectiveLastDisconnectAt = if ($PSBoundParameters.ContainsKey('LastDisconnectAt')) {
        $LastDisconnectAt
    } elseif ($currentState -and $currentState.last_disconnect_at) {
        try { [datetime]::Parse($currentState.last_disconnect_at) } catch { $null }
    } else {
        $null
    }

    $effectiveLastDisconnectReason = if ($PSBoundParameters.ContainsKey('LastDisconnectReason')) {
        $LastDisconnectReason
    } elseif ($currentState) {
        [string] $currentState.last_disconnect_reason
    } else {
        $null
    }

    $effectiveLastDisconnectClassification = if ($PSBoundParameters.ContainsKey('LastDisconnectClassification')) {
        $LastDisconnectClassification
    } elseif ($currentState) {
        [string] $currentState.last_disconnect_classification
    } else {
        $null
    }

    $effectiveLastDisconnectEvidence = if ($PSBoundParameters.ContainsKey('LastDisconnectEvidence')) {
        $LastDisconnectEvidence
    } elseif ($currentState) {
        [string] $currentState.last_disconnect_evidence
    } else {
        $null
    }

    $effectiveLastDisconnectPid = if ($PSBoundParameters.ContainsKey('LastDisconnectPid')) {
        $LastDisconnectPid
    } elseif ($currentState -and $null -ne $currentState.last_disconnect_pid) {
        [int] $currentState.last_disconnect_pid
    } else {
        0
    }

    $effectiveLastDisconnectSessionAgeSeconds = if ($PSBoundParameters.ContainsKey('LastDisconnectSessionAgeSeconds')) {
        $LastDisconnectSessionAgeSeconds
    } elseif ($currentState -and $null -ne $currentState.last_disconnect_session_age_seconds) {
        [double] $currentState.last_disconnect_session_age_seconds
    } else {
        $null
    }

    $effectiveLastFullReconnectAt = if ($PSBoundParameters.ContainsKey('LastFullReconnectAt')) {
        $LastFullReconnectAt
    } elseif ($currentState -and $currentState.last_full_reconnect_at) {
        try { [datetime]::Parse($currentState.last_full_reconnect_at) } catch { $null }
    } else {
        $null
    }

    $effectiveReconnectCount = if ($PSBoundParameters.ContainsKey('ReconnectCount')) {
        $ReconnectCount
    } elseif ($currentState -and $null -ne $currentState.reconnect_count) {
        [int] $currentState.reconnect_count
    } else {
        0
    }

    if (-not $PSBoundParameters.ContainsKey('PredictedSessionExpiryAt') -and $ConnectedAt -and $effectiveNetworkConfigPlan) {
        $effectivePredictedSessionExpiryAt = Get-PredictedSessionExpiryAt -ConnectedAt $ConnectedAt -NetworkConfigPlan $effectiveNetworkConfigPlan
    } elseif ($PSBoundParameters.ContainsKey('PredictedSessionExpiryAt')) {
        $effectivePredictedSessionExpiryAt = $PredictedSessionExpiryAt
    } elseif ($currentState -and $currentState.predicted_session_expiry_at) {
        try { [datetime]::Parse($currentState.predicted_session_expiry_at) } catch { $null }
    } else {
        $null
    }

    if (-not $PSBoundParameters.ContainsKey('PlannedReconnectAt') -and $effectivePredictedSessionExpiryAt) {
        $plannedReconnectSchedule = Get-PlannedReconnectSchedule -PredictedSessionExpiryAt $effectivePredictedSessionExpiryAt
        $effectivePlannedReconnectAt = $plannedReconnectSchedule.PlannedReconnectAt
        $defaultPlannedReconnectReason = $plannedReconnectSchedule.PlannedReconnectReason
    } elseif ($PSBoundParameters.ContainsKey('PlannedReconnectAt')) {
        $effectivePlannedReconnectAt = $PlannedReconnectAt
        $defaultPlannedReconnectReason = $null
    } elseif ($currentState -and $currentState.planned_reconnect_at) {
        try { $effectivePlannedReconnectAt = [datetime]::Parse($currentState.planned_reconnect_at) } catch { $effectivePlannedReconnectAt = $null }
        $defaultPlannedReconnectReason = $null
    } else {
        $effectivePlannedReconnectAt = $null
        $defaultPlannedReconnectReason = $null
    }

    $effectivePlannedReconnectReason = if ($PSBoundParameters.ContainsKey('PlannedReconnectReason')) {
        $PlannedReconnectReason
    } elseif ($defaultPlannedReconnectReason) {
        $defaultPlannedReconnectReason
    } elseif ($currentState) {
        [string] $currentState.planned_reconnect_reason
    } else {
        $null
    }

    if ($ServiceState -eq 'stopped') {
        $effectivePredictedSessionExpiryAt = $null
        $effectivePlannedReconnectAt = $null
        $effectivePlannedReconnectReason = $null
    }

    Write-VpnRuntimeState -StatePath $StateFile -ServiceState $ServiceState -SessionState $SessionState -Reason $Reason -ServicePid $PID -OpenConnectPid $OpenConnectPid -ConnectedAt $ConnectedAt -StartupBlocked $effectiveStartupBlocked -StartupBlockCategory $effectiveStartupBlockCategory -AssignedIp $effectiveAssignedIp -SessionExpiresAt $effectiveSessionExpiresAt -Gateway $effectiveGateway -TransportMode $effectiveTransportMode -TransportChangedAt $effectiveTransportChangedAt -LastTransportEvent $effectiveLastTransportEvent -LastTransportEventAt $effectiveLastTransportEventAt -LastRekeyAt $effectiveLastRekeyAt -LastHipCheckAt $effectiveLastHipCheckAt -LastDpdOkAt $effectiveLastDpdOkAt -NetworkConfigStatus $effectiveNetworkConfigStatus -NetworkConfigSource $effectiveNetworkConfigSource -NetworkConfigError $effectiveNetworkConfigError -NetworkConfigLastUpdated $effectiveNetworkConfigLastUpdated -NetworkConfigPlan $effectiveNetworkConfigPlan -NetworkConflicts $effectiveNetworkConflicts -LastDisconnectAt $effectiveLastDisconnectAt -LastDisconnectReason $effectiveLastDisconnectReason -LastDisconnectClassification $effectiveLastDisconnectClassification -LastDisconnectEvidence $effectiveLastDisconnectEvidence -LastDisconnectPid $effectiveLastDisconnectPid -LastDisconnectSessionAgeSeconds $effectiveLastDisconnectSessionAgeSeconds -LastFullReconnectAt $effectiveLastFullReconnectAt -ReconnectCount $effectiveReconnectCount -PredictedSessionExpiryAt $effectivePredictedSessionExpiryAt -PlannedReconnectAt $effectivePlannedReconnectAt -PlannedReconnectReason $effectivePlannedReconnectReason
}

function Get-PredictedSessionExpiryAt {
    param(
        [AllowNull()] [Nullable[datetime]] $ConnectedAt,
        [psobject] $NetworkConfigPlan
    )

    if (-not $ConnectedAt -or -not $NetworkConfigPlan -or -not $NetworkConfigPlan.Metadata) {
        return $null
    }

    $lifetimeValue = $null
    if ($NetworkConfigPlan.Metadata -is [System.Collections.IDictionary]) {
        if ($NetworkConfigPlan.Metadata.Contains('lifetime')) {
            $lifetimeValue = $NetworkConfigPlan.Metadata['lifetime']
        }
    } elseif ($NetworkConfigPlan.Metadata.PSObject.Properties.Name -contains 'lifetime') {
        $lifetimeValue = $NetworkConfigPlan.Metadata.lifetime
    }

    $lifetimeSeconds = 0
    if ($null -ne $lifetimeValue) {
        [void] [int]::TryParse([string] $lifetimeValue, [ref] $lifetimeSeconds)
    }

    if ($lifetimeSeconds -le 0) {
        return $null
    }

    return ([datetime] $ConnectedAt).AddSeconds($lifetimeSeconds)
}

function Get-PlannedReconnectSchedule {
    param(
        [AllowNull()] [Nullable[datetime]] $PredictedSessionExpiryAt
    )

    $leadSeconds = 300
    if (-not $PredictedSessionExpiryAt) {
        return [PSCustomObject]@{
            PlannedReconnectAt = $null
            PlannedReconnectReason = $null
        }
    }

    $plannedReconnectAt = ([datetime] $PredictedSessionExpiryAt).AddSeconds(-1 * $leadSeconds)
    if ($plannedReconnectAt -le (Get-Date)) {
        return [PSCustomObject]@{
            PlannedReconnectAt = $null
            PlannedReconnectReason = $null
        }
    }

    return [PSCustomObject]@{
        PlannedReconnectAt = $plannedReconnectAt
        PlannedReconnectReason = 'session_lifetime_expiring'
    }
}

function Get-SessionDisconnectDetails {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Summary
    )

    $classification = 'session_lost'
    $reason = 'OpenConnect exited after the session was established.'
    $evidence = $null

    if ($Summary.LastStdErr -match 'Cookie was rejected by server; exiting\.') {
        $classification = 'cookie_rejected'
        $reason = 'GlobalProtect cookie was rejected by the server.'
        $evidence = 'cookie_rejected'
    } elseif ($Summary.NetworkFailureDetected) {
        $classification = 'network_failure'
        $reason = if ($Summary.NetworkFailureReason) { $Summary.NetworkFailureReason } else { 'Network failure detected after session establishment.' }
        $evidence = 'network'
    } elseif ($Summary.AuthFailureDetected) {
        $classification = 'auth_failure'
        $reason = if ($Summary.AuthFailureReason) { $Summary.AuthFailureReason } else { 'Authentication evidence was detected after session establishment.' }
        $evidence = 'auth'
    }

    $sessionAgeSeconds = $null
    if ($Summary.ConnectedAt) {
        $sessionAgeSeconds = [Math]::Round(($Summary.ExitTime - $Summary.ConnectedAt).TotalSeconds, 2)
    }

    return [PSCustomObject]@{
        Classification = $classification
        Reason = $reason
        Evidence = $evidence
        DisconnectedAt = $Summary.ExitTime
        DisconnectPid = $Summary.ProcessId
        SessionAgeSeconds = $sessionAgeSeconds
    }
}

function Test-ServiceStopRequested {
    return (Test-VpnStopRequest -RequestPath $StopRequestFile)
}

function Set-ProtectiveStartupBlock {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Category,

        [Parameter(Mandatory = $true)]
        [string] $Reason
    )

    Update-ServiceRuntimeState -ServiceState 'blocked' -SessionState 'stopped' -Reason $Reason -OpenConnectPid 0 -ConnectedAt $null -StartupBlocked $true -StartupBlockCategory $Category
}

function Clear-ProtectiveStartupBlock {
    param(
        [string] $Reason = 'Startup protection cleared by Stop_VPN.bat.'
    )

    Update-ServiceRuntimeState -ServiceState 'stopped' -SessionState 'stopped' -Reason $Reason -OpenConnectPid 0 -ConnectedAt $null -StartupBlocked $false -StartupBlockCategory $null
}

function Get-StartupGuardState {
    $state = Read-VpnRuntimeState -StatePath $StateFile
    return [PSCustomObject]@{
        IsBlocked = if ($state) { [bool] $state.startup_blocked } else { $false }
        Category = if ($state) { [string] $state.startup_block_category } else { $null }
        Reason = if ($state) { [string] $state.reason } else { $null }
    }
}

function Get-BlockedStartupMessage {
    param(
        [string] $Category,
        [string] $Reason
    )

    $baseMessage = 'VPN startup is blocked after a protective stop. Run Stop_VPN.bat before trying again.'
    if ([string]::IsNullOrWhiteSpace($Reason)) {
        return $baseMessage
    }

    return '{0} Last reason: {1}' -f $baseMessage, $Reason
}

function Test-StartupAllowed {
    $startupGuard = Get-StartupGuardState
    return [PSCustomObject]@{
        Allowed = (-not $startupGuard.IsBlocked)
        Category = $startupGuard.Category
        Reason = $startupGuard.Reason
        Message = if ($startupGuard.IsBlocked) {
            Get-BlockedStartupMessage -Category $startupGuard.Category -Reason $startupGuard.Reason
        } else {
            $null
        }
    }
}

function Get-VpnStartupMutexName {
    param(
        [string] $WorkspacePath = $RootDir
    )

    $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($WorkspacePath))
    $hash = [BitConverter]::ToString($hashBytes).Replace('-', '')
    return 'Global\NTUT_AutoConnectVPN_{0}' -f $hash.Substring(0, 16)
}

function Enter-VpnStartupMutex {
    param(
        [string] $Name = (Get-VpnStartupMutexName)
    )

    $mutex = $null
    try {
        $mutex = [System.Threading.Mutex]::new($false, $Name)
        try {
            $acquired = $mutex.WaitOne(0, $false)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }

        return [PSCustomObject]@{
            Mutex = $mutex
            Acquired = $acquired
        }
    } catch {
        if ($mutex) {
            $mutex.Dispose()
        }

        throw
    }
}

function Exit-VpnStartupMutex {
    param(
        $MutexHandle
    )

    if (-not $MutexHandle) {
        return
    }

    try {
        $MutexHandle.ReleaseMutex()
    } catch {
    }

    try {
        $MutexHandle.Dispose()
    } catch {
    }
}

function Get-NextSessionReconnectAction {
    param(
        [int[]] $DelaysSeconds,
        [int] $AttemptIndex
    )

    $normalizedDelays = @($DelaysSeconds)
    if ($AttemptIndex -lt $normalizedDelays.Count) {
        return [PSCustomObject]@{
            ShouldRetry = $true
            DelaySeconds = $normalizedDelays[$AttemptIndex]
            NextAttemptIndex = $AttemptIndex + 1
        }
    }

    return [PSCustomObject]@{
        ShouldRetry = $false
        DelaySeconds = $null
        NextAttemptIndex = $AttemptIndex
    }
}

function ConvertTo-CommandLineString {
    param(
        [string[]] $Arguments
    )

    if (-not $Arguments) {
        return ''
    }

    $escapedArguments = foreach ($argument in $Arguments) {
        if ($null -eq $argument) {
            '""'
            continue
        }

        if ($argument -match '[\s"]') {
            '"' + ($argument -replace '"', '\"') + '"'
        } else {
            $argument
        }
    }

    return ($escapedArguments -join ' ')
}

foreach ($modulePath in @(
    (Join-Path $ScriptRoot 'lib\openconnect_session.ps1'),
    (Join-Path $ScriptRoot 'lib\network_config_models.ps1'),
    (Join-Path $ScriptRoot 'lib\network_config.ps1')
)) {
    if (-not (Test-Path $modulePath)) {
        Write-Host "Error: module not found at $modulePath"
        exit 1
    }

    . $modulePath
}

function Register-ProcessOutputLogging {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process] $Process,

        [psobject] $ReplayConfigResolution,

        [psobject] $ConnectContext
    )

    $httpDumpEnabled = [bool] (Get-VpnConfig -ConfigKey 'OpenConnectDumpHttpTraffic' -RootDir $RootDir)
    $state = [hashtable]::Synchronized(@{
        LastStdOut = $null
        LastStdErr = $null
        LastActivity = $null
        SessionState = 'launching'
        ConnectedAt = $null
        ProgressAt = $null
        AssignedIp = $null
        SessionExpiresAt = $null
        Gateway = $null
        TransportMode = $null
        TransportChangedAt = $null
        LastTransportEvent = $null
        LastTransportEventAt = $null
        LastRekeyAt = $null
        LastHipCheckAt = $null
        LastDpdOkAt = $null
        AuthFailureDetected = $false
        AuthFailureReason = $null
        NetworkFailureDetected = $false
        NetworkFailureReason = $null
        ScriptWarningDetected = $false
        ScriptWarningReason = $null
        NetworkConfigEvidence = New-NetworkConfigurationEvidence
        PreConnectDnsSnapshot = ConvertTo-DnsSnapshotMap -DnsSettings @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        PreConnectRouteSnapshot = ConvertTo-RouteSnapshotEntries -Routes @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        NetworkConfigStatus = 'not_ready'
        NetworkConfigSource = 'server_derived'
        NetworkConfigError = $null
        NetworkConfigPlan = $null
        NetworkConflicts = @()
        NetworkConfigLastUpdated = $null
        NetworkConfigRouteApplied = $false
        ReplayConfigResolution = $ReplayConfigResolution
        LastDisconnectAt = if ($ConnectContext) { $ConnectContext.LastDisconnectAt } else { $null }
        LastDisconnectReason = if ($ConnectContext) { $ConnectContext.LastDisconnectReason } else { $null }
        LastDisconnectClassification = if ($ConnectContext) { $ConnectContext.LastDisconnectClassification } else { $null }
        LastDisconnectEvidence = if ($ConnectContext) { $ConnectContext.LastDisconnectEvidence } else { $null }
        LastDisconnectPid = if ($ConnectContext) { $ConnectContext.LastDisconnectPid } else { 0 }
        LastDisconnectSessionAgeSeconds = if ($ConnectContext) { $ConnectContext.LastDisconnectSessionAgeSeconds } else { $null }
        LastFullReconnectAt = if ($ConnectContext) { $ConnectContext.LastFullReconnectAt } else { $null }
        ReconnectCount = if ($ConnectContext) { $ConnectContext.ReconnectCount } else { 0 }
        ReconnectPending = if ($ConnectContext) { [bool] $ConnectContext.ReconnectPending } else { $false }
        ReconnectPendingReason = if ($ConnectContext) { $ConnectContext.ReconnectPendingReason } else { $null }
        PredictedSessionExpiryAt = $null
        PlannedReconnectAt = $null
        PlannedReconnectReason = $null
        PlannedReconnectTriggered = $false
        HttpCapture = New-OpenConnectHttpCaptureState -Enabled $httpDumpEnabled
        LastHttpConfigCaptureStatus = if ($httpDumpEnabled) { 'missing' } else { 'disabled' }
        StdOutTask = $Process.StandardOutput.ReadLineAsync()
        StdErrTask = $Process.StandardError.ReadLineAsync()
    })

    return $state
}

function Set-SessionState {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $State,

        [Parameter(Mandatory = $true)]
        [string] $NewState,

        [string] $Component = 'openconnect',

        [string] $Reason,

        [string] $LogPath
    )

    if ($State.SessionState -eq $NewState) {
        return
    }

    $previousState = $State.SessionState
    $State.SessionState = $NewState
    if ($NewState -eq 'connected' -and -not $State.ConnectedAt) {
        $State.ConnectedAt = Get-Date
        if ($State.ReconnectPending) {
            $State.LastFullReconnectAt = $State.ConnectedAt
            $State.ReconnectPending = $false
            $State.ReconnectPendingReason = $null
        }
        $predictedSessionExpiryAt = Get-PredictedSessionExpiryAt -ConnectedAt $State.ConnectedAt -NetworkConfigPlan $State.NetworkConfigPlan
        $plannedReconnectSchedule = Get-PlannedReconnectSchedule -PredictedSessionExpiryAt $predictedSessionExpiryAt
        $State.PredictedSessionExpiryAt = $predictedSessionExpiryAt
        $State.PlannedReconnectAt = $plannedReconnectSchedule.PlannedReconnectAt
        $State.PlannedReconnectReason = $plannedReconnectSchedule.PlannedReconnectReason
        $State.PlannedReconnectTriggered = $false
    }

    $message = 'State transition: {0} -> {1}' -f $previousState, $NewState
    if ($Reason) {
        $message = '{0}; Reason={1}' -f $message, $Reason
    }

    Write-LogEvent -Segments @('supervisor', 'state') -Message ('{0} {1}' -f $Component, $message) -LogPath $LogPath
}

function Update-TransportState {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $State,

        [Parameter(Mandatory = $true)]
        [string] $EventName,

        [string] $TransportMode,

        [Parameter(Mandatory = $true)]
        [string] $Reason,

        [string] $LogPath
    )

    $eventAt = Get-OpenConnectEventTimestamp -Line $Reason
    $State.LastTransportEvent = $EventName
    $State.LastTransportEventAt = $eventAt

    if ($TransportMode -and $State.TransportMode -ne $TransportMode) {
        $previousMode = if ($State.TransportMode) { $State.TransportMode } else { 'unknown' }
        $State.TransportMode = $TransportMode
        $State.TransportChangedAt = $eventAt
        Write-LogEvent -Segments @('supervisor', 'transport') -Message ('Transport transition: {0} -> {1}; Reason={2}' -f $previousMode, $TransportMode, $Reason) -LogPath $LogPath
    } elseif ($EventName -in @('hip_check_due', 'rekey_due', 'dpd_ok', 'https_control_connected')) {
        Write-LogEvent -Segments @('supervisor', 'transport') -Message ('Transport event: {0}; Mode={1}; Reason={2}' -f $EventName, $(if ($State.TransportMode) { $State.TransportMode } else { 'unknown' }), $Reason) -LogPath $LogPath
    }

    Update-ServiceRuntimeState -ServiceState 'running' -SessionState $State.SessionState -Reason $Reason -OpenConnectPid $State.ProcessId -ConnectedAt $State.ConnectedAt -AssignedIp $State.AssignedIp -SessionExpiresAt $State.SessionExpiresAt -Gateway $State.Gateway -TransportMode $State.TransportMode -TransportChangedAt $State.TransportChangedAt -LastTransportEvent $State.LastTransportEvent -LastTransportEventAt $State.LastTransportEventAt -LastRekeyAt $State.LastRekeyAt -LastHipCheckAt $State.LastHipCheckAt -LastDpdOkAt $State.LastDpdOkAt -LastDisconnectAt $State.LastDisconnectAt -LastDisconnectReason $State.LastDisconnectReason -LastDisconnectClassification $State.LastDisconnectClassification -LastDisconnectEvidence $State.LastDisconnectEvidence -LastDisconnectPid $State.LastDisconnectPid -LastDisconnectSessionAgeSeconds $State.LastDisconnectSessionAgeSeconds -LastFullReconnectAt $State.LastFullReconnectAt -ReconnectCount $State.ReconnectCount -PredictedSessionExpiryAt $State.PredictedSessionExpiryAt -PlannedReconnectAt $State.PlannedReconnectAt -PlannedReconnectReason $State.PlannedReconnectReason
}

function Update-RunningSessionRuntimeState {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $State,

        [Parameter(Mandatory = $true)]
        [string] $Reason,

        [string] $SessionStateOverride,

        [switch] $IncludeTransport
    )

    $sessionState = if ($PSBoundParameters.ContainsKey('SessionStateOverride') -and -not [string]::IsNullOrWhiteSpace($SessionStateOverride)) {
        $SessionStateOverride
    } else {
        $State.SessionState
    }

    $runtimeStateArgs = @{
        ServiceState = 'running'
        SessionState = $sessionState
        Reason = $Reason
        OpenConnectPid = $State.ProcessId
        ConnectedAt = $State.ConnectedAt
        AssignedIp = $State.AssignedIp
        SessionExpiresAt = $State.SessionExpiresAt
        Gateway = $State.Gateway
        LastDisconnectAt = $State.LastDisconnectAt
        LastDisconnectReason = $State.LastDisconnectReason
        LastDisconnectClassification = $State.LastDisconnectClassification
        LastDisconnectEvidence = $State.LastDisconnectEvidence
        LastDisconnectPid = $State.LastDisconnectPid
        LastDisconnectSessionAgeSeconds = $State.LastDisconnectSessionAgeSeconds
        LastFullReconnectAt = $State.LastFullReconnectAt
        ReconnectCount = $State.ReconnectCount
        PredictedSessionExpiryAt = $State.PredictedSessionExpiryAt
        PlannedReconnectAt = $State.PlannedReconnectAt
        PlannedReconnectReason = $State.PlannedReconnectReason
    }

    if ($IncludeTransport) {
        $runtimeStateArgs.TransportMode = $State.TransportMode
        $runtimeStateArgs.TransportChangedAt = $State.TransportChangedAt
        $runtimeStateArgs.LastTransportEvent = $State.LastTransportEvent
        $runtimeStateArgs.LastTransportEventAt = $State.LastTransportEventAt
        $runtimeStateArgs.LastRekeyAt = $State.LastRekeyAt
        $runtimeStateArgs.LastHipCheckAt = $State.LastHipCheckAt
        $runtimeStateArgs.LastDpdOkAt = $State.LastDpdOkAt
    }

    Update-ServiceRuntimeState @runtimeStateArgs
}

function Update-OpenConnectSessionStateFromLine {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $State,

        [Parameter(Mandatory = $true)]
        [string] $Line,

        [Parameter(Mandatory = $true)]
        [string] $Component,

        [string] $LogPath
    )

    if (-not $State.ContainsKey('NetworkConfigEvidence') -or $null -eq $State.NetworkConfigEvidence) {
        $State.NetworkConfigEvidence = New-NetworkConfigurationEvidence
    }

    $networkEvidenceChanged = Update-NetworkConfigurationEvidenceFromLine -Evidence $State.NetworkConfigEvidence -Line $Line
    $normalizedLine = Remove-OpenConnectTimestampPrefix -Line $Line

    if ($Line -match 'POST https://' -or $Line -match 'Attempting to connect to server') {
        $State.ProgressAt = Get-Date
        if ($State.SessionState -eq 'launching') {
            Set-SessionState -State $State -NewState 'authenticating' -Component $Component -Reason $Line -LogPath $LogPath
        }
        Update-RunningSessionRuntimeState -State $State -Reason $Line
        if ($networkEvidenceChanged) {
            Update-NetworkConfigurationPreviewState -State $State -ServiceState 'running' -Reason $Line -LogPath $LogPath
        }
        return
    }

    if ($Line -match 'GlobalProtect HIP check due') {
        $State.LastHipCheckAt = Get-OpenConnectEventTimestamp -Line $Line
        Update-TransportState -State $State -EventName 'hip_check_due' -Reason $Line -LogPath $LogPath
        return
    }

    if ($Line -match 'GlobalProtect rekey due') {
        $State.LastRekeyAt = Get-OpenConnectEventTimestamp -Line $Line
        Update-TransportState -State $State -EventName 'rekey_due' -Reason $Line -LogPath $LogPath
        return
    }

    if ($Line -match 'GPST DPD/keepalive response') {
        $State.LastDpdOkAt = Get-OpenConnectEventTimestamp -Line $Line
        Update-TransportState -State $State -EventName 'dpd_ok' -Reason $Line -LogPath $LogPath
        return
    }

    if ($Line -match 'Connecting to HTTPS tunnel endpoint') {
        Update-TransportState -State $State -EventName 'https_tunnel_connecting' -Reason $Line -LogPath $LogPath
        return
    }

    if ($Line -match 'Connected to HTTPS on ') {
        Update-TransportState -State $State -EventName 'https_control_connected' -Reason $Line -LogPath $LogPath
        return
    }

    if ($Line -match 'ESP detected dead peer') {
        Update-TransportState -State $State -EventName 'esp_dead_peer' -Reason $Line -LogPath $LogPath
        return
    }

    if ($Line -match 'Failed to connect ESP tunnel; using HTTPS instead\.') {
        Update-TransportState -State $State -EventName 'https_fallback_active' -TransportMode 'https_fallback' -Reason $Line -LogPath $LogPath
        return
    }

    if (Test-OpenConnectAuthFailureLine -Line $normalizedLine) {
        $State.ProgressAt = Get-Date

        if ($State.SessionState -eq 'connected' -or $State.ConnectedAt) {
            Write-LogEvent -Segments @('supervisor', 'auth') -Message ('Post-connect auth marker observed; retaining connected state. Reason={0}' -f $Line) -LogPath $LogPath
            return
        }

        $State.AuthFailureDetected = $true
        $State.AuthFailureReason = $Line
        if ($State.SessionState -eq 'launching') {
            Set-SessionState -State $State -NewState 'authenticating' -Component $Component -Reason $Line -LogPath $LogPath
        }
        Update-RunningSessionRuntimeState -State $State -Reason $Line -SessionStateOverride 'authenticating'
        return
    }

    if (Test-OpenConnectNetworkFailureEvidence -Line $normalizedLine) {
        $State.ProgressAt = Get-Date
        $State.NetworkFailureDetected = $true
        $State.NetworkFailureReason = $Line
        if ($State.SessionState -eq 'launching') {
            Set-SessionState -State $State -NewState 'authenticating' -Component $Component -Reason $Line -LogPath $LogPath
        }
        Update-RunningSessionRuntimeState -State $State -Reason $Line
        return
    }

    if ($normalizedLine -match 'Failed to complete authentication' -and $State.AuthFailureDetected) {
        $State.ProgressAt = Get-Date
        $State.AuthFailureReason = $normalizedLine
        Update-RunningSessionRuntimeState -State $State -Reason $Line -SessionStateOverride 'authenticating'
        return
    }

    if (Test-OpenConnectConnectedLine -Line $normalizedLine) {
        $State.ProgressAt = Get-Date
        Set-SessionState -State $State -NewState 'connected' -Component $Component -Reason $Line -LogPath $LogPath
        if ($normalizedLine -match 'ESP session established') {
            Update-TransportState -State $State -EventName 'esp_established' -TransportMode 'esp' -Reason $Line -LogPath $LogPath
        } else {
            Update-RunningSessionRuntimeState -State $State -Reason $Line -SessionStateOverride 'connected' -IncludeTransport
        }
        Update-NetworkConfigurationPreviewState -State $State -ServiceState 'running' -Reason $Line -LogPath $LogPath
        return
    }

    if ($normalizedLine -match '^Configured as ([0-9\.]+),') {
        $State.AssignedIp = $Matches[1]
        Update-RunningSessionRuntimeState -State $State -Reason $Line
        Update-NetworkConfigurationPreviewState -State $State -ServiceState 'running' -Reason $Line -LogPath $LogPath
        return
    }

    $expiry = Try-Parse-OpenConnectSessionExpiry -Line $normalizedLine
    if ($expiry) {
        $State.SessionExpiresAt = $expiry
        Update-RunningSessionRuntimeState -State $State -Reason $Line
        return
    }

    if ($normalizedLine -match '^Public VPN Gateway Address:\s*(.+)$') {
        $State.Gateway = $Matches[1].Trim()
        Update-RunningSessionRuntimeState -State $State -Reason $Line
        Update-NetworkConfigurationPreviewState -State $State -ServiceState 'running' -Reason $Line -LogPath $LogPath
        return
    }

    if (Test-OpenConnectScriptWarningLine -Line $Line) {
        $State.ScriptWarningDetected = $true
        $State.ScriptWarningReason = $Line
        Write-LogEvent -Segments @('vpnc-script', 'failure') -Message (Get-OpenConnectScriptWarningSummary -Line $Line) -LogPath $LogPath
        $reasonForState = $Line
        if ($State.SessionState -eq 'connected' -or $State.ConnectedAt) {
            $reasonForState = 'VPN connected, but network configuration script reported warnings. Check vpn_openconnect_raw.log for details.'
        }
        Update-RunningSessionRuntimeState -State $State -Reason $reasonForState -IncludeTransport
        if ($networkEvidenceChanged) {
            Update-NetworkConfigurationPreviewState -State $State -ServiceState 'running' -Reason $reasonForState -LogPath $LogPath
        }
        return
    }

    if ($networkEvidenceChanged) {
        Update-NetworkConfigurationPreviewState -State $State -ServiceState 'running' -Reason $Line -LogPath $LogPath
    }
}

function Write-ProcessStandardInput {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword',
        '',
        Justification = 'OpenConnect requires plaintext data on stdin. The password remains encrypted at rest and is converted only for the final handoff to the child process.'
    )]
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process] $Process,

        [string[]] $InputLines,

        [string] $LogPath
    )

    try {
        $linesToWrite = if ($null -eq $InputLines) { @() } else { @($InputLines) }

        foreach ($line in $linesToWrite) {
            $Process.StandardInput.WriteLine($line)
        }

        $Process.StandardInput.Flush()
        $Process.StandardInput.Close()
    } catch {
        Write-LogEvent -Segments @('supervisor', 'stdin') -Message ("Failed to write child process stdin: {0}" -f $_) -LogPath $LogPath
    }
}

function Get-ProcessSummary {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process] $Process,

        [Parameter(Mandatory = $true)]
        [datetime] $StartedAt,

        [Parameter(Mandatory = $true)]
        [hashtable] $State
    )

    $exitTime = $null
    try {
        $exitTime = $Process.ExitTime
    } catch {
        $exitTime = Get-Date
    }

    $duration = [Math]::Round(($exitTime - $StartedAt).TotalSeconds, 2)
    return [PSCustomObject]@{
        ProcessId = $Process.Id
        ExitCode = $Process.ExitCode
        StartedAt = $StartedAt
        ExitTime = $exitTime
        DurationSeconds = $duration
        LastStdOut = $State.LastStdOut
        LastStdErr = $State.LastStdErr
        LastActivity = $State.LastActivity
        SessionState = $State.SessionState
        ConnectedAt = $State.ConnectedAt
        ProgressAt = $State.ProgressAt
        AssignedIp = $State.AssignedIp
        SessionExpiresAt = $State.SessionExpiresAt
        Gateway = $State.Gateway
        TransportMode = $State.TransportMode
        TransportChangedAt = $State.TransportChangedAt
        LastTransportEvent = $State.LastTransportEvent
        LastTransportEventAt = $State.LastTransportEventAt
        LastRekeyAt = $State.LastRekeyAt
        LastHipCheckAt = $State.LastHipCheckAt
        LastDpdOkAt = $State.LastDpdOkAt
        AuthFailureDetected = $State.AuthFailureDetected
        AuthFailureReason = $State.AuthFailureReason
        NetworkFailureDetected = $State.NetworkFailureDetected
        NetworkFailureReason = $State.NetworkFailureReason
        ScriptWarningDetected = $State.ScriptWarningDetected
        ScriptWarningReason = $State.ScriptWarningReason
    }
}

function Get-OpenConnectStandardInputLines {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword',
        '',
        Justification = 'OpenConnect consumes plaintext secrets from stdin. The repeated values remain in-memory only for the child-process handoff.'
    )]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Password,

        [int] $RepeatCount = 1
    )

    $normalizedRepeatCount = [Math]::Max($RepeatCount, 1)
    $inputLines = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $normalizedRepeatCount; $index++) {
        $inputLines.Add($Password)
    }

    return @($inputLines)
}

function Write-ProcessSummaryLog {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Summary,

        [Parameter(Mandatory = $true)]
        [string[]] $Segments,

        [Parameter(Mandatory = $true)]
        [string] $Message,

        [string] $LogPath
    )

    $lastStdOut = if ($Summary.LastStdOut) { $Summary.LastStdOut } else { '<none>' }
    $lastStdErr = if ($Summary.LastStdErr) { $Summary.LastStdErr } else { '<none>' }
    $lastActivity = if ($Summary.LastActivity) { Get-Date $Summary.LastActivity -Format 'yyyy-MM-dd HH:mm:ss' } else { '<none>' }
    $sessionState = if ($Summary.SessionState) { $Summary.SessionState } else { '<unknown>' }

    $assignedIp = if ($Summary.AssignedIp) { $Summary.AssignedIp } else { '<none>' }
    $sessionExpiresAt = if ($Summary.SessionExpiresAt) { (Get-Date $Summary.SessionExpiresAt -Format 'yyyy-MM-dd HH:mm:ss') } else { '<none>' }
    $gateway = if ($Summary.Gateway) { $Summary.Gateway } else { '<none>' }
    $transportMode = if ($Summary.TransportMode) { $Summary.TransportMode } else { '<none>' }
    $lastTransportEvent = if ($Summary.LastTransportEvent) { $Summary.LastTransportEvent } else { '<none>' }
    $flags = @()
    if ($Summary.AuthFailureDetected) { $flags += 'auth' }
    if ($Summary.NetworkFailureDetected) { $flags += 'network' }
    if ($Summary.ScriptWarningDetected) { $flags += 'script-warning' }
    $flagText = if ($flags.Count -gt 0) { $flags -join ',' } else { '<none>' }
    $scriptWarning = if ($Summary.ScriptWarningReason) { $Summary.ScriptWarningReason } else { '<none>' }

    Write-LogEvent -Segments $Segments -Message (
        '{0} PID={1}; ExitCode={2}; DurationSeconds={3}; SessionState={4}; TransportMode={5}; LastTransportEvent={6}; AssignedIp={7}; SessionExpiresAt={8}; Gateway={9}; Evidence={10}; ScriptWarning={11}; LastStdOut={12}; LastStdErr={13}; LastActivity={14}' -f
        $Message, $Summary.ProcessId, $Summary.ExitCode, $Summary.DurationSeconds, $sessionState, $transportMode, $lastTransportEvent, $assignedIp, $sessionExpiresAt, $gateway, $flagText, $scriptWarning, $lastStdOut, $lastStdErr, $lastActivity
    ) -LogPath $LogPath
}

function Read-AvailableProcessOutput {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process] $Process,

        [Parameter(Mandatory = $true)]
        [hashtable] $State,

        [Parameter(Mandatory = $true)]
        [string] $Component,

        [string] $LogPath
    )

    $streamMap = @(
        @{ Reader = $Process.StandardOutput; Segment = 'stdout'; StateKey = 'LastStdOut'; TaskKey = 'StdOutTask' },
        @{ Reader = $Process.StandardError; Segment = 'stderr'; StateKey = 'LastStdErr'; TaskKey = 'StdErrTask' }
    )

    foreach ($stream in $streamMap) {
        $reader = $stream.Reader
        while ($State[$stream.TaskKey] -and $State[$stream.TaskKey].IsCompleted) {
            $line = $State[$stream.TaskKey].Result
            $State[$stream.TaskKey] = $null

            if ($null -eq $line) {
                break
            }

            $State[$stream.TaskKey] = $reader.ReadLineAsync()
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            $State[$stream.StateKey] = $line
            $State.LastActivity = Get-Date
            $normalizedLine = Remove-OpenConnectTimestampPrefix -Line $line
            $httpCaptureHandled = Add-OpenConnectHttpCaptureLine -CaptureState $State.HttpCapture -Component $Component -Stream $stream.Segment -RawLine $line -NormalizedLine $normalizedLine -DumpFile $OpenConnectHttpDumpFile -BodyDumpFile $OpenConnectHttpBodyDumpFile
            if (-not $httpCaptureHandled) {
                Write-RawLogLine -Component $Component -Stream $stream.Segment -Message $line -LogPath $OpenConnectRawLogFile
            }
            Update-OpenConnectSessionStateFromLine -State $State -Line $line -Component $Component -LogPath $LogPath
        }
    }

    if ($Process.HasExited) {
        Complete-OpenConnectHttpCaptureState -CaptureState $State.HttpCapture -BodyDumpFile $OpenConnectHttpBodyDumpFile
    }

    Write-HttpConfigCaptureStatusEvent -State $State -LogPath $LogPath
}

function Write-HttpConfigCaptureStatusEvent {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $State,

        [string] $LogPath
    )

    if (-not $State.HttpCapture) {
        return
    }

    $metadata = Get-OpenConnectHttpCapturePlanMetadata -CaptureState $State.HttpCapture -DumpFile $OpenConnectHttpDumpFile -BodyDumpFile $OpenConnectHttpBodyDumpFile
    $currentStatus = [string] $metadata.http_config_capture_status
    if ($State.LastHttpConfigCaptureStatus -eq $currentStatus) {
        return
    }

    $State.LastHttpConfigCaptureStatus = $currentStatus
    $message = 'HTTP config capture status changed to {0}' -f $currentStatus
    if ($metadata.xml_capture_blocked_reason) {
        $message = '{0}; Reason={1}' -f $message, $metadata.xml_capture_blocked_reason
    }

    Write-LogEvent -Segments @('http-config', $currentStatus) -Message $message -LogPath $LogPath
}

function Wait-ForStableProcessWindow {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process] $Process,

        [Parameter(Mandatory = $true)]
        [hashtable] $State,

        [Parameter(Mandatory = $true)]
        [string] $Component,

        [int] $ObservationSeconds = 3,

        [string] $LogPath
    )

    if ($ObservationSeconds -le 0) {
        return $true
    }

    $deadline = (Get-Date).AddSeconds($ObservationSeconds)
    while ((Get-Date) -lt $deadline) {
        Read-AvailableProcessOutput -Process $Process -State $State -Component $Component -LogPath $LogPath
        if ($Process.HasExited) {
            return $false
        }

        Start-Sleep -Milliseconds 200
    }

    Read-AvailableProcessOutput -Process $Process -State $State -Component $Component -LogPath $LogPath
    return (-not $Process.HasExited)
}

function Wait-ForConnectedSession {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process] $Process,

        [Parameter(Mandatory = $true)]
        [hashtable] $State,

        [Parameter(Mandatory = $true)]
        [string] $Component,

        [int] $HeartbeatSeconds = 60,

        [scriptblock] $OnConnected,

        [string] $LogPath
    )

    $lastHeartbeatAt = Get-Date
    $connectionNotified = $false

    while (-not $Process.HasExited) {
        Read-AvailableProcessOutput -Process $Process -State $State -Component $Component -LogPath $LogPath

        if ($State.SessionState -eq 'connected') {
            if ($OnConnected -and -not $connectionNotified) {
                & $OnConnected $Process
                $connectionNotified = $true
            }

            return [PSCustomObject]@{
                Connected = $true
                ConnectionNotified = $connectionNotified
            }
        }

        $now = Get-Date
        if (($now - $lastHeartbeatAt).TotalSeconds -ge $HeartbeatSeconds) {
            $uptimeSeconds = [Math]::Round(($now - $Process.StartTime).TotalSeconds, 2)
            $lastStdOut = if ($State.LastStdOut) { $State.LastStdOut } else { '<none>' }
            $lastStdErr = if ($State.LastStdErr) { $State.LastStdErr } else { '<none>' }

            Write-LogEvent -Segments @('supervisor', 'waiting') -Message (
                '{0} PID={1} awaiting connected marker; State={2}; TransportMode={3}; LastTransportEvent={4}; UptimeSeconds={5}; LastStdOut={6}; LastStdErr={7}' -f
                $Component, $Process.Id, $State.SessionState, $(if ($State.TransportMode) { $State.TransportMode } else { '<none>' }), $(if ($State.LastTransportEvent) { $State.LastTransportEvent } else { '<none>' }), $uptimeSeconds, $lastStdOut, $lastStdErr
            ) -LogPath $LogPath

            $lastHeartbeatAt = $now
        }

        Start-Sleep -Milliseconds 200
    }

    Read-AvailableProcessOutput -Process $Process -State $State -Component $Component -LogPath $LogPath
    return [PSCustomObject]@{
        Connected = $false
        ConnectionNotified = $false
    }
}

function Wait-ProcessWithHeartbeat {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process] $Process,

        [Parameter(Mandatory = $true)]
        [datetime] $StartedAt,

        [Parameter(Mandatory = $true)]
        [hashtable] $State,

        [Parameter(Mandatory = $true)]
        [string] $Component,

        [int] $HeartbeatSeconds = 60,

        [string] $LogPath
    )

    $lastHeartbeatAt = Get-Date
    while (-not $Process.HasExited) {
        Read-AvailableProcessOutput -Process $Process -State $State -Component $Component -LogPath $LogPath

        $now = Get-Date
        if (($now - $lastHeartbeatAt).TotalSeconds -ge $HeartbeatSeconds) {
            $uptimeSeconds = [Math]::Round(($now - $StartedAt).TotalSeconds, 2)
            $lastStdOut = if ($State.LastStdOut) { $State.LastStdOut } else { '<none>' }
            $lastStdErr = if ($State.LastStdErr) { $State.LastStdErr } else { '<none>' }

            Write-LogEvent -Segments @('supervisor', 'heartbeat') -Message (
                '{0} PID={1} still running; TransportMode={2}; LastTransportEvent={3}; UptimeSeconds={4}; LastStdOut={5}; LastStdErr={6}' -f
                $Component, $Process.Id, $(if ($State.TransportMode) { $State.TransportMode } else { '<none>' }), $(if ($State.LastTransportEvent) { $State.LastTransportEvent } else { '<none>' }), $uptimeSeconds, $lastStdOut, $lastStdErr
            ) -LogPath $LogPath

            $lastHeartbeatAt = $now
        }

        Start-Sleep -Milliseconds 200
    }

    Start-Sleep -Milliseconds 100
    Read-AvailableProcessOutput -Process $Process -State $State -Component $Component -LogPath $LogPath

    try {
        $Process.WaitForExit()
    } catch {
        Write-LogEvent -Segments @('supervisor', 'wait') -Message ("Failed while waiting for process exit: {0}" -f $_) -LogPath $LogPath
    }

    return (Get-ProcessSummary -Process $Process -StartedAt $StartedAt -State $State)
}

function Cleanup-ProcessResources {
    param(
        [System.Diagnostics.Process] $Process,
        [string] $LogPath
    )

    if (-not $Process) {
        return
    }

    try {
        $Process.Dispose()
        Write-LogEvent -Segments @('supervisor', 'cleanup') -Message 'Child process resources cleaned up.' -LogPath $LogPath
    } catch {
        Write-LogEvent -Segments @('supervisor', 'cleanup') -Message ("Failed to dispose child process: {0}" -f $_) -LogPath $LogPath
    }
}

function Get-PreConnectFailureClassification {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Summary,

        [switch] $ProgressObserved
    )

    if ($Summary.AuthFailureDetected -and -not $Summary.NetworkFailureDetected) {
        return 'auth_failure'
    }

    if ($Summary.NetworkFailureDetected -and -not $Summary.AuthFailureDetected) {
        return 'network_failure'
    }

    if ($Summary.AuthFailureDetected -and $Summary.NetworkFailureDetected) {
        return 'unknown_failure'
    }

    if ($ProgressObserved) {
        return 'connect_failure'
    }

    return 'unknown_failure'
}

function Invoke-SupervisedProcess {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword',
        '',
        Justification = 'OpenConnect requires plaintext data on stdin. The password remains encrypted at rest and is converted only for the final handoff to the child process.'
    )]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Executable,

        [string[]] $Arguments,

        [string[]] $InputLines,

        [Parameter(Mandatory = $true)]
        [string] $Component,

        [string] $DisplayArguments,

        [int] $InitialObservationSeconds = 3,

        [int] $HeartbeatSeconds = 60,

        [scriptblock] $OnStableProcess,

        [string] $LogPath,

        [hashtable] $EnvironmentVariables,

        [psobject] $ReplayConfigResolution,

        [psobject] $ConnectContext
    )

    $proc = $null
    $state = $null
    $startedAt = Get-Date

    try {
        $startResult = Start-ChildProcess -Executable $Executable -Arguments $Arguments -EnvironmentVariables $EnvironmentVariables
        if (-not $startResult.Started) {
            $errorMessage = if ($startResult.Error) { $startResult.Error } else { 'Unknown start failure.' }
            Write-LogEvent -Segments @('supervisor', 'launch') -Message ("Failed to start {0}: {1}" -f $Component, $errorMessage) -LogPath $LogPath
            return [PSCustomObject]@{
                Classification = 'start_failure'
                ProcessId = $null
                ExitCode = $null
                DurationSeconds = 0
                LastStdOut = $null
                LastStdErr = $null
                LastActivity = $null
            }
        }

        $proc = $startResult.Process
        $startedAt = Get-Date
        Write-LogEvent -Segments @('supervisor', 'launch') -Message (
            'Started {0} PID={1}; Args={2}' -f
            $Component, $proc.Id, $DisplayArguments
        ) -LogPath $LogPath

        $state = Register-ProcessOutputLogging -Process $proc -ReplayConfigResolution $ReplayConfigResolution -ConnectContext $ConnectContext
        $state.ProcessId = $proc.Id
        Update-ServiceRuntimeState -ServiceState 'running' -SessionState $state.SessionState -Reason ('Started {0}' -f $Component) -OpenConnectPid $proc.Id -ConnectedAt $null -TransportMode $state.TransportMode -TransportChangedAt $state.TransportChangedAt -LastTransportEvent $state.LastTransportEvent -LastTransportEventAt $state.LastTransportEventAt -LastRekeyAt $state.LastRekeyAt -LastHipCheckAt $state.LastHipCheckAt -LastDpdOkAt $state.LastDpdOkAt

        Write-ProcessStandardInput -Process $proc -InputLines $InputLines -LogPath $LogPath

        $reachedStableWindow = Wait-ForStableProcessWindow -Process $proc -State $state -Component $Component -ObservationSeconds $InitialObservationSeconds -LogPath $LogPath
        if (-not $reachedStableWindow) {
            $summary = Get-ProcessSummary -Process $proc -StartedAt $startedAt -State $state
            $failureClassification = Get-PreConnectFailureClassification -Summary $summary
            return [PSCustomObject]@{
                Classification = $failureClassification
                ProcessId = $summary.ProcessId
                ExitCode = $summary.ExitCode
                DurationSeconds = $summary.DurationSeconds
                LastStdOut = $summary.LastStdOut
                LastStdErr = $summary.LastStdErr
                LastActivity = $summary.LastActivity
                SessionState = $summary.SessionState
                AuthFailureDetected = $summary.AuthFailureDetected
                AuthFailureReason = $summary.AuthFailureReason
                NetworkFailureDetected = $summary.NetworkFailureDetected
                NetworkFailureReason = $summary.NetworkFailureReason
                ScriptWarningDetected = $summary.ScriptWarningDetected
                ScriptWarningReason = $summary.ScriptWarningReason
                AssignedIp = $summary.AssignedIp
                SessionExpiresAt = $summary.SessionExpiresAt
                Gateway = $summary.Gateway
            }
        }

        $connectedSession = Wait-ForConnectedSession -Process $proc -State $state -Component $Component -HeartbeatSeconds $HeartbeatSeconds -OnConnected $OnStableProcess -LogPath $LogPath
        if (-not $connectedSession.Connected) {
            $summary = Get-ProcessSummary -Process $proc -StartedAt $startedAt -State $state
            $failureClassification = Get-PreConnectFailureClassification -Summary $summary -ProgressObserved
            return [PSCustomObject]@{
                Classification = $failureClassification
                ProcessId = $summary.ProcessId
                ExitCode = $summary.ExitCode
                DurationSeconds = $summary.DurationSeconds
                LastStdOut = $summary.LastStdOut
                LastStdErr = $summary.LastStdErr
                LastActivity = $summary.LastActivity
                SessionState = $summary.SessionState
                AuthFailureDetected = $summary.AuthFailureDetected
                AuthFailureReason = $summary.AuthFailureReason
                NetworkFailureDetected = $summary.NetworkFailureDetected
                NetworkFailureReason = $summary.NetworkFailureReason
                ScriptWarningDetected = $summary.ScriptWarningDetected
                ScriptWarningReason = $summary.ScriptWarningReason
                AssignedIp = $summary.AssignedIp
                SessionExpiresAt = $summary.SessionExpiresAt
                Gateway = $summary.Gateway
            }
        }

        $summary = Wait-ProcessWithHeartbeat -Process $proc -StartedAt $startedAt -State $state -Component $Component -HeartbeatSeconds $HeartbeatSeconds -LogPath $LogPath
        return [PSCustomObject]@{
            Classification = 'session_exit'
            ProcessId = $summary.ProcessId
            ExitCode = $summary.ExitCode
            DurationSeconds = $summary.DurationSeconds
            LastStdOut = $summary.LastStdOut
            LastStdErr = $summary.LastStdErr
            LastActivity = $summary.LastActivity
            SessionState = $summary.SessionState
            AuthFailureDetected = $summary.AuthFailureDetected
            AuthFailureReason = $summary.AuthFailureReason
            NetworkFailureDetected = $summary.NetworkFailureDetected
            NetworkFailureReason = $summary.NetworkFailureReason
            ScriptWarningDetected = $summary.ScriptWarningDetected
            ScriptWarningReason = $summary.ScriptWarningReason
            AssignedIp = $summary.AssignedIp
            SessionExpiresAt = $summary.SessionExpiresAt
            Gateway = $summary.Gateway
            ConnectedAt = $summary.ConnectedAt
            DisconnectDetails = (Get-SessionDisconnectDetails -Summary $summary)
            PlannedReconnectTriggered = [bool] $state.PlannedReconnectTriggered
        }
    } catch {
        Write-LogEvent -Segments @('supervisor', 'launch') -Message ("Exception while supervising {0}: {1}" -f $Component, $_) -LogPath $LogPath
        return [PSCustomObject]@{
            Classification = 'start_failure'
            ProcessId = $null
            ExitCode = $null
            DurationSeconds = 0
            LastStdOut = $null
            LastStdErr = $null
            LastActivity = $null
            SessionState = 'launching'
            AuthFailureDetected = $false
            AuthFailureReason = $null
            NetworkFailureDetected = $false
            NetworkFailureReason = $null
            ScriptWarningDetected = $false
            ScriptWarningReason = $null
            AssignedIp = $null
            SessionExpiresAt = $null
            Gateway = $null
        }
    } finally {
        Cleanup-ProcessResources -Process $proc -LogPath $LogPath
    }
}

function Remove-ServicePidFile {
    param(
        [string] $PidPath = $PidFile,
        [string] $LogPath = $LogFile
    )

    try {
        if (Test-Path $PidPath) {
            Remove-Item $PidPath -Force -ErrorAction Stop
            Write-LogEvent -Segments @('service', 'pid') -Message ("Removed PID file: {0}" -f $PidPath) -LogPath $LogPath
        }
    } catch {
        Write-LogEvent -Segments @('service', 'pid') -Message ("Failed to remove PID file {0}: {1}" -f $PidPath, $_) -LogPath $LogPath
    }
}

function Stop-ExistingOpenConnectProcesses {
    param(
        [string] $Reason,
        [int] $TerminationDelaySeconds = 2,
        [string] $LogPath = $LogFile
    )

    $existingProcesses = @(Get-Process 'openconnect' -ErrorAction SilentlyContinue)
    if ($existingProcesses.Count -eq 0) {
        return
    }

    Write-LogEvent -Segments @('openconnect', 'cleanup') -Message (
        'Cleaning up {0} existing OpenConnect process(es): {1}' -f
        $existingProcesses.Count, $Reason
    ) -LogPath $LogPath

    foreach ($process in $existingProcesses) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            Write-LogEvent -Segments @('openconnect', 'cleanup') -Message ("Stopped orphaned OpenConnect PID={0}" -f $process.Id) -LogPath $LogPath
        } catch {
            Write-LogEvent -Segments @('openconnect', 'cleanup') -Message ("Failed to stop OpenConnect PID={0}: {1}" -f $process.Id, $_) -LogPath $LogPath
        }
    }

    Start-Sleep -Seconds $TerminationDelaySeconds
}

function Invoke-OpenConnectSession {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword',
        '',
        Justification = 'The password remains encrypted at rest and is converted only for the final handoff to the child process.'
    )]
    param(
        [string] $Executable,
        [string] $Username,
        [string] $Password,
        [string] $TargetServer,
        [string] $StatusScript,
        [string] $PidPath,
        [string] $Protocol = 'gp',
        [int] $VerboseOutput = 1,
        [bool] $TimestampOutput = $true,
        [int] $ReconnectTimeoutSeconds = 0,
        [bool] $NoDtls = $false,
        [bool] $DumpHttpTraffic = $false,
        [int] $PasswordStdinRepeatCount = 1,
        [string] $ScriptCommand,
        [int] $HeartbeatSeconds = 60,
        [int] $TerminationDelaySeconds = 2,
        [psobject] $ReplayConfigResolution,
        [psobject] $ConnectContext
    )

    Write-LogEvent -Segments @('supervisor', 'connect') -Message ("Attempting to connect to {0}" -f $TargetServer) -LogPath $LogFile
    Stop-ExistingOpenConnectProcesses -Reason 'before new supervised launch' -TerminationDelaySeconds $TerminationDelaySeconds -LogPath $LogFile

    $arguments = Get-OpenConnectArguments -Username $Username -TargetServer $TargetServer -Protocol $Protocol -VerboseLevel $VerboseOutput -TimestampOutput $TimestampOutput -ReconnectTimeoutSeconds $ReconnectTimeoutSeconds -NoDtls $NoDtls -DumpHttpTraffic $DumpHttpTraffic -ScriptCommand $ScriptCommand -NonInteractive $true
    $displayArguments = ConvertTo-CommandLineString -Arguments $arguments
    $stdinLines = Get-OpenConnectStandardInputLines -Password $Password -RepeatCount $PasswordStdinRepeatCount

    $result = Invoke-SupervisedProcess -Executable $Executable -Arguments $arguments -InputLines $stdinLines -Component 'openconnect' -DisplayArguments $displayArguments -InitialObservationSeconds 3 -HeartbeatSeconds $HeartbeatSeconds -LogPath $LogFile -OnStableProcess {
        param($Process)
        Write-LogEvent -Segments @('supervisor', 'connect') -Message ("Connected: OpenConnect running (PID: {0})" -f $Process.Id) -LogPath $LogFile
        Show-StatusWindow -StatusScript $StatusScript
    } -EnvironmentVariables (Get-OpenConnectScriptEnvironment -RootDir $RootDir) -ReplayConfigResolution $ReplayConfigResolution -ConnectContext $ConnectContext

    if (Test-ServiceStopRequested) {
        Write-LogEvent -Segments @('supervisor', 'stop') -Message 'Stop request detected; suppressing further session result handling.' -LogPath $LogFile
        return [PSCustomObject]@{
            Classification = 'stop_requested'
            ShouldRetry = $false
            ExitCode = $result.ExitCode
        }
    }

    switch ($result.Classification) {
        'connect_failure' {
            Write-ProcessSummaryLog -Summary $result -Segments @('supervisor', 'connect') -Message 'OpenConnect exited before a connected session marker was observed.' -LogPath $LogFile
            Stop-ExistingOpenConnectProcesses -Reason 'after supervised connect failure' -TerminationDelaySeconds $TerminationDelaySeconds -LogPath $LogFile

            return [PSCustomObject]@{
                Classification = 'connect_failure'
                ShouldRetry = $false
                ExitCode = $result.ExitCode
            }
        }
        'network_failure' {
            Write-ProcessSummaryLog -Summary $result -Segments @('supervisor', 'network') -Message 'OpenConnect failed before connection due to explicit network evidence.' -LogPath $LogFile
            Stop-ExistingOpenConnectProcesses -Reason 'after supervised network failure' -TerminationDelaySeconds $TerminationDelaySeconds -LogPath $LogFile

            return [PSCustomObject]@{
                Classification = 'network_failure'
                ShouldRetry = $false
                ExitCode = $result.ExitCode
            }
        }
        'auth_failure' {
            Write-ProcessSummaryLog -Summary $result -Segments @('supervisor', 'auth') -Message 'Authentication/login failed before the VPN tunnel was established.' -LogPath $LogFile

            return [PSCustomObject]@{
                Classification = 'auth_failure'
                ShouldRetry = $false
                ExitCode = $result.ExitCode
            }
        }
        'unknown_failure' {
            Write-ProcessSummaryLog -Summary $result -Segments @('supervisor', 'unknown') -Message 'OpenConnect stopped before connection and the failure evidence was mixed or incomplete.' -LogPath $LogFile
            Stop-ExistingOpenConnectProcesses -Reason 'after supervised unknown failure' -TerminationDelaySeconds $TerminationDelaySeconds -LogPath $LogFile

            return [PSCustomObject]@{
                Classification = 'unknown_failure'
                ShouldRetry = $false
                ExitCode = $result.ExitCode
            }
        }
        'session_exit' {
            Write-ProcessSummaryLog -Summary $result -Segments @('supervisor', 'disconnect') -Message 'OpenConnect exited after the session was established.' -LogPath $LogFile
            Stop-ExistingOpenConnectProcesses -Reason 'after supervised session exit' -TerminationDelaySeconds $TerminationDelaySeconds -LogPath $LogFile

            return [PSCustomObject]@{
                Classification = 'session_lost'
                ShouldRetry = $true
                ExitCode = $result.ExitCode
                DisconnectDetails = $result.DisconnectDetails
            }
        }
        'stop_requested' {
            return [PSCustomObject]@{
                Classification = 'stop_requested'
                ShouldRetry = $false
                ExitCode = $result.ExitCode
            }
        }
        default {
            Write-LogEvent -Segments @('supervisor', 'launch') -Message 'OpenConnect did not start successfully.' -LogPath $LogFile
            return [PSCustomObject]@{
                Classification = 'start_failure'
                ShouldRetry = $false
                ExitCode = $result.ExitCode
            }
        }
    }
}

function Start-VpnService {
    $SetCredScript = Join-Path $ScriptRoot 'Set_VPN_Credential.ps1'
    $StatusScript = Join-Path $ScriptRoot 'Check_VPN_Status.ps1'
    $ReconnectDelay = Get-VpnConfig -ConfigKey 'ReconnectDelay' -RootDir $RootDir
    $SessionReconnectDelays = @(Get-VpnConfig -ConfigKey 'SessionReconnectDelays' -RootDir $RootDir)
    $RetryInitialConnectFailure = Get-VpnConfig -ConfigKey 'RetryInitialConnectFailure' -RootDir $RootDir
    $RetryAuthFailure = Get-VpnConfig -ConfigKey 'RetryAuthFailure' -RootDir $RootDir
    $TerminationDelay = Get-VpnConfig -ConfigKey 'ProcessTerminationDelay' -RootDir $RootDir
    $OpenConnectVerbose = Get-VpnConfig -ConfigKey 'OpenConnectVerbose' -RootDir $RootDir
    $OpenConnectTimestamp = Get-VpnConfig -ConfigKey 'OpenConnectTimestamp' -RootDir $RootDir
    $OpenConnectReconnectTimeout = Get-VpnConfig -ConfigKey 'OpenConnectReconnectTimeoutSeconds' -RootDir $RootDir
    $OpenConnectNoDtls = Get-VpnConfig -ConfigKey 'OpenConnectNoDtls' -RootDir $RootDir
    $OpenConnectScriptCommand = Get-VpnConfig -ConfigKey 'OpenConnectScriptCommand' -RootDir $RootDir
    $SupervisorHeartbeatSeconds = Get-VpnConfig -ConfigKey 'SupervisorHeartbeatSeconds' -RootDir $RootDir
    $ReplayConfigEnabled = Get-VpnConfig -ConfigKey 'ReplayConfigEnabled' -RootDir $RootDir
    $ReplayCacheFile = Get-VpnConfig -ConfigKey 'ReplayCacheFile' -RootDir $RootDir
    $ReplayOutputRoot = Get-VpnConfig -ConfigKey 'ReplayOutputRoot' -RootDir $RootDir
    $ReplayCacheTtlHours = Get-VpnConfig -ConfigKey 'ReplayCacheTtlHours' -RootDir $RootDir
    $serviceExitCode = 0
    $shutdownReason = 'Requested shutdown'
    $sessionRecoveryAttemptIndex = 0
    $inSessionRecoveryMode = $false
    $reconnectCount = 0
    $lastFullReconnectAt = $null
    $startupMutexHandle = $null
    $preserveStartupBlock = $false

    try {
        $startupMutex = Enter-VpnStartupMutex
        if (-not $startupMutex.Acquired) {
            $serviceExitCode = 1
            $shutdownReason = 'Startup refused because another startup is already in progress'
            Write-LogEvent -Segments @('service', 'guard') -Message $shutdownReason -LogPath $LogFile
            Show-ServiceNotification -Title 'VPN Startup Blocked' -Message 'Another VPN startup is already in progress. Wait for it to finish before trying again.' -LogPath $LogFile
            exit $serviceExitCode
        }

        $startupMutexHandle = $startupMutex.Mutex

        if (Test-Path $PidFile) {
            $ExistingPid = Get-Content $PidFile -ErrorAction SilentlyContinue
            if ($ExistingPid -and (Get-Process -Id $ExistingPid -ErrorAction SilentlyContinue)) {
                Write-LogEvent -Segments @('service', 'pid') -Message "VPN monitor service is already running (PID: $ExistingPid)" -LogPath $LogFile
        if (Get-VpnConfig -ConfigKey 'ServiceInteractiveOutput' -RootDir $RootDir) {
            Write-Host "VPN monitor service is already running (PID: $ExistingPid). Exiting." -ForegroundColor Yellow
        }
                exit 0
            } else {
                Write-LogEvent -Segments @('service', 'pid') -Message "Stale PID file found (PID: $ExistingPid). Cleaning up and recovering." -LogPath $LogFile
                Remove-ServicePidFile -PidPath $PidFile -LogPath $LogFile
            }
        }

        $startupGuard = Test-StartupAllowed
        if (-not $startupGuard.Allowed) {
            $serviceExitCode = 1
            $shutdownReason = 'Startup blocked by protective stop'
            $preserveStartupBlock = $true
            Write-LogEvent -Segments @('service', 'guard') -Message ("Blocked startup attempt refused. Category={0}; Reason={1}" -f $startupGuard.Category, $startupGuard.Reason) -LogPath $LogFile
            Show-ServiceNotification -Title 'VPN Startup Blocked' -Message $startupGuard.Message -LogPath $LogFile
            exit $serviceExitCode
        }

        Clear-VpnStopRequest -RequestPath $StopRequestFile

        Set-WorkingContext -PidPath $PidFile -WorkingDirectory $WorkDir
        Write-LogEvent -Segments @('service', 'start') -Message "=== VPN monitor started (Service PID: $PID) ===" -LogPath $LogFile
        Update-ServiceRuntimeState -ServiceState 'starting' -SessionState 'launching' -Reason 'VPN monitor service started' -OpenConnectPid 0 -ConnectedAt $null -StartupBlocked $false -StartupBlockCategory $null
        if (Get-VpnConfig -ConfigKey 'ServiceInteractiveOutput' -RootDir $RootDir) {
            Write-Host "VPN Monitor Service Started" -ForegroundColor Green
            Write-Host "Note: VPN connections may be interrupted every 4 hours by the server." -ForegroundColor Yellow
            Write-Host "      Automatic reconnect is only used after a confirmed session loss." -ForegroundColor Yellow
            Write-Host ""
        }

        $CredCandidates = @((Join-Path $ScriptRoot 'vpn_cred.xml'), (Join-Path $WorkDir 'vpn_cred.xml'))
        $CredData = Get-CredentialData -Candidates $CredCandidates -SetupScript $SetCredScript

        if (-not $CredData) {
            $serviceExitCode = 1
            $shutdownReason = 'Credential setup did not complete successfully'
            Update-ServiceRuntimeState -ServiceState 'stopped' -SessionState 'stopped' -Reason $shutdownReason -OpenConnectPid 0 -ConnectedAt $null
            if (Get-VpnConfig -ConfigKey 'ServiceInteractiveOutput' -RootDir $RootDir) {
                Write-Host "Credential setup did not complete successfully. Service will exit." -ForegroundColor Yellow
            }
            Write-LogEvent -Segments @('service', 'credential') -Message $shutdownReason -LogPath $LogFile
            Remove-ServicePidFile -PidPath $PidFile -LogPath $LogFile
            exit $serviceExitCode
        }

        $credential = $CredData.Credential
        $User = $credential.UserName
        $Password = SecureStringToPlainText $credential.Password
        $replayConfigResolution = if ($ReplayConfigEnabled) {
            Resolve-ReplayConfigurationPlan -RootDir $RootDir -Server $Server -UserName $User -CredentialFile $CredData.Path -CachePath $ReplayCacheFile -OutputRoot $ReplayOutputRoot -TtlHours $ReplayCacheTtlHours -LogPath $LogFile
        } else {
            [PSCustomObject]@{
                Status = 'disabled'
                Source = 'disabled'
                Plan = $null
                Error = $null
                ReplayDirectory = $null
            }
        }

        while ($true) {
            $shouldContinueService = $true
            $connectContext = [PSCustomObject]@{
                LastDisconnectAt = $null
                LastDisconnectReason = $null
                LastDisconnectClassification = $null
                LastDisconnectEvidence = $null
                LastDisconnectPid = 0
                LastDisconnectSessionAgeSeconds = $null
                LastFullReconnectAt = $lastFullReconnectAt
                ReconnectCount = $reconnectCount
                ReconnectPending = ($inSessionRecoveryMode -or $reconnectCount -gt 0)
                ReconnectPendingReason = if ($inSessionRecoveryMode) { 'session_lost' } else { $null }
            }
            $wasReconnectAttempt = [bool] $connectContext.ReconnectPending

            $session = Invoke-OpenConnectSession -Executable $OpenConnectExe -Username $User -Password $Password -TargetServer $Server -StatusScript $StatusScript -PidPath $PidFile -Protocol $Protocol -VerboseOutput $OpenConnectVerbose -TimestampOutput $OpenConnectTimestamp -ReconnectTimeoutSeconds $OpenConnectReconnectTimeout -NoDtls $OpenConnectNoDtls -DumpHttpTraffic (Get-VpnConfig -ConfigKey 'OpenConnectDumpHttpTraffic' -RootDir $RootDir) -PasswordStdinRepeatCount (Get-VpnConfig -ConfigKey 'OpenConnectPasswordStdinRepeatCount' -RootDir $RootDir) -ScriptCommand $OpenConnectScriptCommand -HeartbeatSeconds $SupervisorHeartbeatSeconds -TerminationDelaySeconds $TerminationDelay -ReplayConfigResolution $replayConfigResolution -ConnectContext $connectContext
            $inSessionRecoveryMode = $false

            switch ($session.Classification) {
                'stop_requested' {
                    $serviceExitCode = 0
                    $shutdownReason = 'Stop requested by Stop_VPN.bat.'
                    $shouldContinueService = $false
                    break
                }
                'session_lost' {
                    if ($session.DisconnectDetails) {
                        Update-ServiceRuntimeState -ServiceState 'running' -SessionState 'stopped' -Reason $session.DisconnectDetails.Reason -OpenConnectPid 0 -ConnectedAt $null -LastDisconnectAt $session.DisconnectDetails.DisconnectedAt -LastDisconnectReason $session.DisconnectDetails.Reason -LastDisconnectClassification $session.DisconnectDetails.Classification -LastDisconnectEvidence $session.DisconnectDetails.Evidence -LastDisconnectPid $session.DisconnectDetails.DisconnectPid -LastDisconnectSessionAgeSeconds $session.DisconnectDetails.SessionAgeSeconds -LastFullReconnectAt $lastFullReconnectAt -ReconnectCount $reconnectCount
                    }
                    if (Test-ServiceStopRequested) {
                        $serviceExitCode = 0
                        $shutdownReason = 'Stop requested by Stop_VPN.bat.'
                        $shouldContinueService = $false
                        break
                    }
                    $inSessionRecoveryMode = $true
                    $sessionRecoveryAttemptIndex = 0
                    $reconnectCount += 1
                    $reconnectAction = Get-NextSessionReconnectAction -DelaysSeconds $SessionReconnectDelays -AttemptIndex $sessionRecoveryAttemptIndex

                    if (-not $reconnectAction.ShouldRetry) {
                        $serviceExitCode = 1
                        $shutdownReason = 'Session lost with no reconnect budget configured'
                        $preserveStartupBlock = $true
                        Set-ProtectiveStartupBlock -Category 'retry_budget_exhausted' -Reason $shutdownReason
                        Show-ServiceNotification -Title 'VPN Reconnect Stopped' -Message 'The VPN session was lost and no reconnect attempts are configured. Start_VPN.bat is required to try again.' -LogPath $LogFile
                        $shouldContinueService = $false
                        break
                    }

                    $sessionRecoveryAttemptIndex = $reconnectAction.NextAttemptIndex
                    $shutdownReason = 'Reconnecting after session loss'
                    Update-ServiceRuntimeState -ServiceState 'reconnecting' -SessionState 'stopped' -Reason $shutdownReason -OpenConnectPid 0 -ConnectedAt $null -LastDisconnectAt $session.DisconnectDetails.DisconnectedAt -LastDisconnectReason $session.DisconnectDetails.Reason -LastDisconnectClassification $session.DisconnectDetails.Classification -LastDisconnectEvidence $session.DisconnectDetails.Evidence -LastDisconnectPid $session.DisconnectDetails.DisconnectPid -LastDisconnectSessionAgeSeconds $session.DisconnectDetails.SessionAgeSeconds -LastFullReconnectAt $lastFullReconnectAt -ReconnectCount $reconnectCount
                    Write-LogEvent -Segments @('service', 'retry') -Message ("Session reconnect attempt {0}/{1} in {2} seconds." -f $sessionRecoveryAttemptIndex, $SessionReconnectDelays.Count, $reconnectAction.DelaySeconds) -LogPath $LogFile
                    if (Get-VpnConfig -ConfigKey 'ServiceInteractiveOutput' -RootDir $RootDir) {
                        Write-Host "Reconnecting in $($reconnectAction.DelaySeconds) seconds..." -ForegroundColor Cyan
                    }
                    if (Test-ServiceStopRequested) {
                        $serviceExitCode = 0
                        $shutdownReason = 'Stop requested by Stop_VPN.bat.'
                        $shouldContinueService = $false
                        break
                    }
                    Start-Sleep -Seconds $reconnectAction.DelaySeconds
                    continue
                }
                'connect_failure' {
                    if ($wasReconnectAttempt) {
                        $reconnectAction = Get-NextSessionReconnectAction -DelaysSeconds $SessionReconnectDelays -AttemptIndex $sessionRecoveryAttemptIndex
                        if ($reconnectAction.ShouldRetry) {
                            $sessionRecoveryAttemptIndex = $reconnectAction.NextAttemptIndex
                            $shutdownReason = 'Retrying session recovery after connect failure'
                            Update-ServiceRuntimeState -ServiceState 'reconnecting' -SessionState 'stopped' -Reason $shutdownReason -OpenConnectPid 0 -ConnectedAt $null
                            Write-LogEvent -Segments @('service', 'retry') -Message ("Session recovery connect failure. Next attempt {0}/{1} in {2} seconds." -f $sessionRecoveryAttemptIndex, $SessionReconnectDelays.Count, $reconnectAction.DelaySeconds) -LogPath $LogFile
                            if (Get-VpnConfig -ConfigKey 'ServiceInteractiveOutput' -RootDir $RootDir) {
                                Write-Host "Retrying session recovery in $($reconnectAction.DelaySeconds) seconds..." -ForegroundColor Cyan
                            }
                            if (Test-ServiceStopRequested) {
                                $serviceExitCode = 0
                                $shutdownReason = 'Stop requested by Stop_VPN.bat.'
                                $shouldContinueService = $false
                                break
                            }
                            Start-Sleep -Seconds $reconnectAction.DelaySeconds
                            continue
                        }

                        $serviceExitCode = 1
                        $shutdownReason = 'Session recovery retry budget exhausted'
                        $preserveStartupBlock = $true
                        Set-ProtectiveStartupBlock -Category 'retry_budget_exhausted' -Reason $shutdownReason
                        Show-ServiceNotification -Title 'VPN Reconnect Stopped' -Message 'Automatic reconnect attempts have stopped after repeated connection failures. Start_VPN.bat is required to try again.' -LogPath $LogFile
                        $shouldContinueService = $false
                        break
                    }

                    if ($RetryInitialConnectFailure) {
                        $shutdownReason = 'Retrying initial connection failure'
                        Update-ServiceRuntimeState -ServiceState 'reconnecting' -SessionState 'stopped' -Reason $shutdownReason -OpenConnectPid 0 -ConnectedAt $null
                        Write-LogEvent -Segments @('service', 'retry') -Message "Initial connection failed. Retrying in $ReconnectDelay seconds..." -LogPath $LogFile
                        if (Test-ServiceStopRequested) {
                            $serviceExitCode = 0
                            $shutdownReason = 'Stop requested by Stop_VPN.bat.'
                            $shouldContinueService = $false
                            break
                        }
                        Start-Sleep -Seconds $ReconnectDelay
                        continue
                    }

                    $serviceExitCode = 1
                    $shutdownReason = 'Initial connection failed before session establishment'
                    $preserveStartupBlock = $true
                    Set-ProtectiveStartupBlock -Category 'connect_failure' -Reason $shutdownReason
                    Show-ServiceNotification -Title 'VPN Connection Failed' -Message 'The VPN connection could not be established. Please verify network connectivity or try again later.' -LogPath $LogFile
                    $shouldContinueService = $false
                    break
                }
                'auth_failure' {
                    if ($RetryAuthFailure) {
                        $shutdownReason = 'Retrying authentication failure'
                        Update-ServiceRuntimeState -ServiceState 'reconnecting' -SessionState 'stopped' -Reason $shutdownReason -OpenConnectPid 0 -ConnectedAt $null
                        Write-LogEvent -Segments @('service', 'retry') -Message "Authentication failed. Retrying in $ReconnectDelay seconds..." -LogPath $LogFile
                        if (Test-ServiceStopRequested) {
                            $serviceExitCode = 0
                            $shutdownReason = 'Stop requested by Stop_VPN.bat.'
                            $shouldContinueService = $false
                            break
                        }
                        Start-Sleep -Seconds $ReconnectDelay
                        continue
                    }

                    $serviceExitCode = 1
                    $shutdownReason = 'Authentication/setup failure'
                    $preserveStartupBlock = $true
                    Set-ProtectiveStartupBlock -Category 'auth_failure' -Reason $shutdownReason
                    Show-ServiceNotification -Title 'VPN Authentication Failed' -Message 'VPN authentication failed. Please verify your username, password, or network access before trying again.' -LogPath $LogFile
                    $shouldContinueService = $false
                    break
                }
                'network_failure' {
                    $serviceExitCode = 1
                    $shutdownReason = 'Network/setup failure before session establishment'
                    $preserveStartupBlock = $true
                    Set-ProtectiveStartupBlock -Category 'network_failure' -Reason $shutdownReason
                    Show-ServiceNotification -Title 'VPN Network Failed' -Message 'The VPN connection failed due to DNS or network connectivity problems. Review vpn_history.log and the raw OpenConnect log before trying again.' -LogPath $LogFile
                    $shouldContinueService = $false
                    break
                }
                'unknown_failure' {
                    $serviceExitCode = 1
                    $shutdownReason = 'Unknown setup failure before session establishment'
                    $preserveStartupBlock = $true
                    Set-ProtectiveStartupBlock -Category 'unknown_failure' -Reason $shutdownReason
                    Show-ServiceNotification -Title 'VPN Startup Stopped' -Message 'The VPN connection stopped before a session was established and the failure reason was mixed or incomplete. Review vpn_history.log and the raw OpenConnect log before trying again.' -LogPath $LogFile
                    $shouldContinueService = $false
                    break
                }
                default {
                    $serviceExitCode = 1
                    $shutdownReason = 'OpenConnect failed to start'
                    Update-ServiceRuntimeState -ServiceState 'stopped' -SessionState 'stopped' -Reason $shutdownReason -OpenConnectPid 0 -ConnectedAt $null
                    Show-ServiceNotification -Title 'VPN Service Stopped' -Message 'OpenConnect did not start successfully. Review vpn_history.log before trying again.' -LogPath $LogFile
                    $shouldContinueService = $false
                    break
                }
            }

            if (-not $shouldContinueService) {
                break
            }
        }
    } catch {
        $serviceExitCode = 1
        $shutdownReason = 'Unhandled service exception'
        Update-ServiceRuntimeState -ServiceState 'stopped' -SessionState 'stopped' -Reason $shutdownReason -OpenConnectPid 0 -ConnectedAt $null
        Write-LogEvent -Segments @('service', 'fatal') -Message ("Unhandled VPN monitor exception: {0}" -f $_) -LogPath $LogFile
        throw
    } finally {
        Update-ServiceRuntimeState -ServiceState 'stopped' -SessionState 'stopped' -Reason $shutdownReason -OpenConnectPid 0 -ConnectedAt $null -StartupBlocked ($(if ($preserveStartupBlock) { $true } else { $null }))
        Write-LogEvent -Segments @('service', 'stop') -Message ("VPN monitor stopping. Reason={0}; ExitCode={1}" -f $shutdownReason, $serviceExitCode) -LogPath $LogFile
        Show-TerminalStatusWindow -StatusScript $StatusScript -ExitCode $serviceExitCode -ShutdownReason $shutdownReason
        Remove-ServicePidFile -PidPath $PidFile -LogPath $LogFile
        Exit-VpnStartupMutex -MutexHandle $startupMutexHandle
    }

    exit $serviceExitCode
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-VpnService
}
