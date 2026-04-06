# Shared helpers for VPN scripts
# - Write-Log: write timestamped lines to $LogFile (expects $LogFile variable set in caller)
# - Ensure-Credential: prompt once for password (for a given user) and save encrypted to file (Export-Clixml)

function Write-Log {
    param(
        [Parameter(Mandatory=$true)] [string] $Message,
        [string] $LogPath
    )
    if (-not $LogPath) { $LogPath = $env:LOGFILE }
    if (-not $LogPath) { return }
    $directory = Split-Path -Parent $LogPath
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "[$TimeStamp] $Message"
    # Ensure UTF8 without BOM for consistent appending across processes
    Add-Content -Path $LogPath -Value $LogLine -Encoding UTF8
}

function Format-LogPrefix {
    param(
        [string[]] $Segments
    )

    $cleanSegments = @($Segments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($cleanSegments.Count -eq 0) {
        return ''
    }

    return ('[' + ($cleanSegments -join '][') + ']')
}

function Write-LogEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Segments,

        [Parameter(Mandatory = $true)]
        [string] $Message,

        [string] $LogPath
    )

    $prefix = Format-LogPrefix -Segments $Segments
    $formattedMessage = if ($prefix) { '{0} {1}' -f $prefix, $Message } else { $Message }
    Write-Log -Message $formattedMessage -LogPath $LogPath
}

function Write-RawLogLine {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Component,

        [Parameter(Mandatory = $true)]
        [string] $Stream,

        [Parameter(Mandatory = $true)]
        [string] $Message,

        [string] $LogPath
    )

    Write-LogEvent -Segments @($Component, $Stream) -Message $Message -LogPath $LogPath
}

function Ensure-Credential {
    param(
        [Parameter(Mandatory=$true)] [string] $CredFile,
        [Parameter(Mandatory=$true)] [string] $User
    )
    # Return a PSCredential. If $CredFile exists, import it; otherwise prompt for password and save.
    if (Test-Path $CredFile) {
        try {
            $cred = Import-Clixml -Path $CredFile
            if ($cred -is [System.Management.Automation.PSCredential]) { return $cred }
        } catch {
            # corrupted or unreadable, fall through to prompt
        }
    }

    # Prompt for password (silent) and save credential
    Write-Host "Enter password for user: $User"
    $pw = Read-Host -AsSecureString "Password" 
    $cred = New-Object System.Management.Automation.PSCredential ($User, $pw)
    try {
        $cred | Export-Clixml -Path $CredFile
        Write-Host "Credential saved to $CredFile (encrypted for this user)."
    } catch {
        Write-Host "Warning: failed to save credential: $_"
    }
    return $cred
}

function SecureStringToPlainText($secure) {
    if (-not $secure) { return '' }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Test-ContainsNonAscii {
    param(
        [string] $Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return ($Text -match '[^\u0000-\u007F]')
}

function Normalize-RuntimeReasonText {
    param(
        [string] $Reason
    )

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        return $Reason
    }

    $normalizedReason = $Reason.Trim()

    # Strip one or more leading bracketed prefixes, e.g.:
    # [2026-04-06 13:37:00] ...
    # [openconnect][stderr] ...
    while ($normalizedReason -match '^\[[^\]]+\]\s*(.+)$') {
        $normalizedReason = $Matches[1]
    }

    if ($normalizedReason -match '(?i)\bReason\s*=\s*(.+)$') {
        $normalizedReason = $Matches[1]
    }

    if ($normalizedReason -match '^(.*?);\s*ExitCode\s*=\s*-?\d+\s*$') {
        $normalizedReason = $Matches[1]
    }

    # Keep runtime state reasons readable and stable by collapsing repeated whitespace.
    $normalizedReason = [System.Text.RegularExpressions.Regex]::Replace($normalizedReason, '\s+', ' ')
    return $normalizedReason.Trim()
}

function ConvertTo-EnglishRuntimeReason {
    param(
        [string] $Reason
    )

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        return $Reason
    }

    $trimmed = Normalize-RuntimeReasonText -Reason $Reason
    $normalized = $trimmed.ToLowerInvariant()

    if ($normalized -match 'esp session established') {
        return 'VPN tunnel established (ESP session active).'
    }

    if ($normalized -match '^connected$') {
        return 'VPN connected.'
    }

    if ($normalized -match 'connected to https on') {
        return 'HTTPS control channel connected.'
    }

    if ($normalized -match '^opened tun device\b') {
        return 'VPN tunnel device opened.'
    }

    if ($normalized -match '^using tap-windows device\b') {
        return 'VPN tunnel adapter selected.'
    }

    if ($normalized -match 'failed to connect esp tunnel; using https instead') {
        return 'ESP tunnel unavailable; switched to HTTPS fallback transport.'
    }

    if ($normalized -match 'x-private-pan-globalprotect:\s*auth-failed') {
        return 'Authentication failed (GlobalProtect auth-failed).'
    }

    if ($normalized -match 'unexpected 512 result from server') {
        return 'Authentication response was rejected by server (unexpected result 512).'
    }

    if ($normalized -match 'failed to complete authentication') {
        return 'Authentication could not be completed.'
    }

    if ($normalized -match 'user input required in non-interactive mode') {
        return 'Authentication failed because interactive input is required.'
    }

    if ($normalized -match 'getaddrinfo failed|could not be resolved|name or service not known|temporary failure in name resolution') {
        return 'Network error: failed to resolve VPN server hostname.'
    }

    if ($normalized -match 'failed to open https connection|failed to connect to host|connection refused|no route to host|timed out') {
        return 'Network error: failed to connect to VPN server over HTTPS.'
    }

    if ($normalized -match 'script did not complete within') {
        return 'VPN network configuration script timed out.'
    }

    if ($normalized -match 'vpnc-script|script .* returned error') {
        return 'VPN network configuration script failed. Check vpn_openconnect_raw.log for details.'
    }

    if (Test-ContainsNonAscii -Text $trimmed) {
        return 'OpenConnect reported a localized or non-English event. Check vpn_openconnect_raw.log for details.'
    }

    return $trimmed
}

function Write-VpnRuntimeState {
    param(
        [Parameter(Mandatory = $true)] [string] $StatePath,
        [Parameter(Mandatory = $true)] [string] $ServiceState,
        [Parameter(Mandatory = $true)] [string] $SessionState,
        [string] $Reason,
        [int] $ServicePid,
        [int] $OpenConnectPid,
        [AllowNull()] [Nullable[datetime]] $ConnectedAt,
        [bool] $StartupBlocked = $false,
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
        [string] $PlannedReconnectReason,
        [datetime] $LastUpdated = (Get-Date)
    )

    $stateDirectory = Split-Path -Parent $StatePath
    if ($stateDirectory -and -not (Test-Path $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $englishReason = ConvertTo-EnglishRuntimeReason -Reason $Reason
    $englishLastDisconnectReason = ConvertTo-EnglishRuntimeReason -Reason $LastDisconnectReason

    $payload = [ordered]@{
        service_state   = $ServiceState
        session_state   = $SessionState
        reason          = $englishReason
        startup_blocked = $StartupBlocked
        startup_block_category = $StartupBlockCategory
        service_pid     = if ($ServicePid -gt 0) { $ServicePid } else { $null }
        openconnect_pid = if ($OpenConnectPid -gt 0) { $OpenConnectPid } else { $null }
        connected_at    = if ($ConnectedAt) { (Get-Date $ConnectedAt -Format 'o') } else { $null }
        assigned_ip     = if ($AssignedIp) { $AssignedIp } else { $null }
        session_expires_at = if ($SessionExpiresAt) { (Get-Date $SessionExpiresAt -Format 'o') } else { $null }
        gateway         = if ($Gateway) { $Gateway } else { $null }
        transport_mode  = if ($TransportMode) { $TransportMode } else { $null }
        transport_changed_at = if ($TransportChangedAt) { (Get-Date $TransportChangedAt -Format 'o') } else { $null }
        last_transport_event = if ($LastTransportEvent) { $LastTransportEvent } else { $null }
        last_transport_event_at = if ($LastTransportEventAt) { (Get-Date $LastTransportEventAt -Format 'o') } else { $null }
        last_rekey_at   = if ($LastRekeyAt) { (Get-Date $LastRekeyAt -Format 'o') } else { $null }
        last_hip_check_at = if ($LastHipCheckAt) { (Get-Date $LastHipCheckAt -Format 'o') } else { $null }
        last_dpd_ok_at  = if ($LastDpdOkAt) { (Get-Date $LastDpdOkAt -Format 'o') } else { $null }
        network_config_status = if ($NetworkConfigStatus) { $NetworkConfigStatus } else { $null }
        network_config_source = if ($NetworkConfigSource) { $NetworkConfigSource } else { $null }
        network_config_error = if ($NetworkConfigError) { $NetworkConfigError } else { $null }
        network_config_last_updated = if ($NetworkConfigLastUpdated) { (Get-Date $NetworkConfigLastUpdated -Format 'o') } else { $null }
        network_config_plan = if ($NetworkConfigPlan) { $NetworkConfigPlan } else { $null }
        network_conflicts = @($NetworkConflicts)
        last_disconnect_at = if ($LastDisconnectAt) { (Get-Date $LastDisconnectAt -Format 'o') } else { $null }
        last_disconnect_reason = if ($englishLastDisconnectReason) { $englishLastDisconnectReason } else { $null }
        last_disconnect_classification = if ($LastDisconnectClassification) { $LastDisconnectClassification } else { $null }
        last_disconnect_evidence = if ($LastDisconnectEvidence) { $LastDisconnectEvidence } else { $null }
        last_disconnect_pid = if ($LastDisconnectPid -gt 0) { $LastDisconnectPid } else { $null }
        last_disconnect_session_age_seconds = if ($null -ne $LastDisconnectSessionAgeSeconds) { [double] $LastDisconnectSessionAgeSeconds } else { $null }
        last_full_reconnect_at = if ($LastFullReconnectAt) { (Get-Date $LastFullReconnectAt -Format 'o') } else { $null }
        reconnect_count = if ($ReconnectCount -gt 0) { $ReconnectCount } else { 0 }
        predicted_session_expiry_at = if ($PredictedSessionExpiryAt) { (Get-Date $PredictedSessionExpiryAt -Format 'o') } else { $null }
        planned_reconnect_at = if ($PlannedReconnectAt) { (Get-Date $PlannedReconnectAt -Format 'o') } else { $null }
        planned_reconnect_reason = if ($PlannedReconnectReason) { $PlannedReconnectReason } else { $null }
        last_updated    = (Get-Date $LastUpdated -Format 'o')
    }

    $json = $payload | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($StatePath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Read-VpnRuntimeState {
    param(
        [Parameter(Mandatory = $true)] [string] $StatePath
    )

    if (-not (Test-Path $StatePath)) {
        return $null
    }

    try {
        return (Get-Content -Path $StatePath -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Remove-VpnRuntimeState {
    param(
        [Parameter(Mandatory = $true)] [string] $StatePath
    )

    if (Test-Path $StatePath) {
        Remove-Item -Path $StatePath -Force -ErrorAction SilentlyContinue
    }
}

function Set-VpnStopRequest {
    param(
        [Parameter(Mandatory = $true)] [string] $RequestPath,
        [datetime] $RequestedAt = (Get-Date)
    )

    $requestDirectory = Split-Path -Parent $RequestPath
    if ($requestDirectory -and -not (Test-Path $requestDirectory)) {
        New-Item -ItemType Directory -Path $requestDirectory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($RequestPath, (Get-Date $RequestedAt -Format 'o'), [System.Text.UTF8Encoding]::new($false))
}

function Test-VpnStopRequest {
    param(
        [Parameter(Mandatory = $true)] [string] $RequestPath
    )

    return (Test-Path $RequestPath)
}

function Clear-VpnStopRequest {
    param(
        [Parameter(Mandatory = $true)] [string] $RequestPath
    )

    if (Test-Path $RequestPath) {
        Remove-Item -Path $RequestPath -Force -ErrorAction SilentlyContinue
    }
}

# This file is intended for dot-sourcing (`. ./lib/vpn_common.ps1`).
# No module registration is required here.
