$repoRoot = Split-Path -Parent $PSScriptRoot
$libPath = Join-Path $repoRoot 'src/lib/vpn_common.ps1'
. $libPath

Describe 'vpn_common helpers' {
    It 'writes timestamped lines to the specified log file' {
        $logPath = Join-Path $TestDrive 'vpn_history.log'
        $env:LOGFILE = $logPath

        Write-Log -Message 'hello world' -LogPath $logPath

        $content = Get-Content -Path $logPath -Raw
        $content | Should Match 'hello world'
        $content | Should Match '\d{4}-\d{2}-\d{2}'
    }

    It 'writes structured log prefixes through Write-LogEvent' {
        $logPath = Join-Path $TestDrive 'vpn_history.log'
        $env:LOGFILE = $logPath

        Write-LogEvent -Segments @('supervisor', 'heartbeat') -Message 'child still running' -LogPath $logPath

        $content = Get-Content -Path $logPath -Raw
        $content | Should Match '\[supervisor\]\[heartbeat\] child still running'
    }

    It 'writes raw log lines with stream prefixes' {
        $logPath = Join-Path $TestDrive 'vpn_openconnect_raw.log'
        $env:LOGFILE = $logPath

        Write-RawLogLine -Component 'openconnect' -Stream 'stderr' -Message 'Failed to open HTTPS connection' -LogPath $logPath

        $content = Get-Content -Path $logPath -Raw
        $content | Should Match '\[openconnect\]\[stderr\] Failed to open HTTPS connection'
    }

    It 'converts secure strings back to plaintext' {
        $secure = ConvertTo-SecureString -String 'p@ssw0rd' -AsPlainText -Force

        $plain = SecureStringToPlainText $secure

        $plain | Should Be 'p@ssw0rd'
    }

    It 'writes and reads runtime state with startup guard and reconnect observability fields' {
        $statePath = Join-Path $TestDrive 'vpn_state.json'
        $plan = [pscustomobject]@{
            assigned_ip = '172.24.232.72'
            dns_servers = @('8.8.8.8')
            dns_target_interface_index = 18
            dns_owned_servers = @('8.8.8.8')
            route_target_interface_index = 18
            route_owned_entries = @(
                [pscustomobject]@{
                    destination_prefix = '140.124.0.0/16'
                    interface_index = 18
                    next_hop = '0.0.0.0'
                }
            )
        }
        $conflicts = @(
            [pscustomobject]@{
                kind = 'route_overlap'
                scope = '140.124.0.0/16'
                summary = 'Existing route already present.'
            }
        )
        $connectedAt = Get-Date
        $lastDisconnectAt = $connectedAt.AddHours(4)
        $lastFullReconnectAt = $lastDisconnectAt.AddSeconds(12)
        $predictedSessionExpiryAt = $connectedAt.AddHours(4)
        $plannedReconnectAt = $connectedAt.AddHours(3).AddMinutes(55)

        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'blocked' -SessionState 'stopped' -Reason 'Authentication/setup failure' -ServicePid 1000 -OpenConnectPid 0 -ConnectedAt $connectedAt -StartupBlocked $true -StartupBlockCategory 'auth_failure' -AssignedIp '172.24.232.72' -SessionExpiresAt $predictedSessionExpiryAt -Gateway '140.124.4.100' -TransportMode 'esp' -TransportChangedAt (Get-Date).AddMinutes(-5) -LastTransportEvent 'esp_established' -LastTransportEventAt (Get-Date).AddMinutes(-5) -LastRekeyAt (Get-Date).AddMinutes(-10) -LastHipCheckAt (Get-Date).AddMinutes(-15) -LastDpdOkAt (Get-Date).AddMinutes(-1) -NetworkConfigStatus 'conflict_detected' -NetworkConfigSource 'server_derived' -NetworkConfigError 'Existing VPN adapter detected.' -NetworkConfigLastUpdated (Get-Date) -NetworkConfigPlan $plan -NetworkConflicts $conflicts -LastDisconnectAt $lastDisconnectAt -LastDisconnectReason 'GlobalProtect cookie was rejected by the server.' -LastDisconnectClassification 'cookie_rejected' -LastDisconnectEvidence 'cookie_rejected' -LastDisconnectPid 2880 -LastDisconnectSessionAgeSeconds 14426.84 -LastFullReconnectAt $lastFullReconnectAt -ReconnectCount 1 -PredictedSessionExpiryAt $predictedSessionExpiryAt -PlannedReconnectAt $plannedReconnectAt -PlannedReconnectReason 'session_lifetime_expiring'
        $state = Read-VpnRuntimeState -StatePath $statePath

        $state.service_state | Should Be 'blocked'
        $state.startup_blocked | Should Be $true
        $state.startup_block_category | Should Be 'auth_failure'
        $state.assigned_ip | Should Be '172.24.232.72'
        $state.gateway | Should Be '140.124.4.100'
        $state.transport_mode | Should Be 'esp'
        $state.last_transport_event | Should Be 'esp_established'
        $state.network_config_status | Should Be 'conflict_detected'
        $state.network_config_source | Should Be 'server_derived'
        $state.network_config_plan.assigned_ip | Should Be '172.24.232.72'
        $state.network_config_plan.dns_target_interface_index | Should Be 18
        $state.network_config_plan.route_target_interface_index | Should Be 18
        $state.network_conflicts[0].kind | Should Be 'route_overlap'
        $state.last_disconnect_reason | Should Be 'GlobalProtect cookie was rejected by the server.'
        $state.last_disconnect_classification | Should Be 'cookie_rejected'
        $state.last_disconnect_evidence | Should Be 'cookie_rejected'
        $state.last_disconnect_pid | Should Be 2880
        [double] $state.last_disconnect_session_age_seconds | Should Be 14426.84
        $state.reconnect_count | Should Be 1
        $state.planned_reconnect_reason | Should Be 'session_lifetime_expiring'
    }

    It 'normalizes auth failure and non-ASCII runtime reasons to English' {
        $statePath = Join-Path $TestDrive 'vpn_state.json'

        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'running' -SessionState 'authenticating' -Reason 'Unexpected 512 result from server' -ServicePid 1000 -OpenConnectPid 222 -ConnectedAt $null -LastDisconnectReason '認證失敗'
        $state = Read-VpnRuntimeState -StatePath $statePath

        $state.reason | Should Be 'Authentication response was rejected by server (unexpected result 512).'
        $state.last_disconnect_reason | Should Be 'OpenConnect reported a localized or non-English event. Check vpn_openconnect_raw.log for details.'
    }

    It 'normalizes timestamp-prefixed OpenConnect reason lines before mapping to English' {
        $statePath = Join-Path $TestDrive 'vpn_state.json'

        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'running' -SessionState 'authenticating' -Reason '[2026-04-06 13:37:00] X-Private-Pan-Globalprotect: auth-failed' -ServicePid 1000 -OpenConnectPid 222 -ConnectedAt $null
        $state = Read-VpnRuntimeState -StatePath $statePath

        $state.reason | Should Be 'Authentication failed (GlobalProtect auth-failed).'
    }

    It 'normalizes bracketed stream prefixes before mapping to English' {
        $statePath = Join-Path $TestDrive 'vpn_state.json'

        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'running' -SessionState 'authenticating' -Reason '[openconnect][stderr] Unexpected 512 result from server' -ServicePid 1000 -OpenConnectPid 222 -ConnectedAt $null
        $state = Read-VpnRuntimeState -StatePath $statePath

        $state.reason | Should Be 'Authentication response was rejected by server (unexpected result 512).'
    }

    It 'collapses repeated whitespace in unmapped runtime reasons' {
        $statePath = Join-Path $TestDrive 'vpn_state.json'

        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'running' -SessionState 'authenticating' -Reason '  custom   diagnostic   event  ' -ServicePid 1000 -OpenConnectPid 222 -ConnectedAt $null
        $state = Read-VpnRuntimeState -StatePath $statePath

        $state.reason | Should Be 'custom diagnostic event'
    }

    It 'extracts the inner reason when runtime reason contains Reason wrapper text' {
        $statePath = Join-Path $TestDrive 'vpn_state.json'

        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'stopped' -SessionState 'stopped' -Reason 'VPN monitor stopping. Reason=Authentication/setup failure; ExitCode=1' -ServicePid 1000 -OpenConnectPid 0 -ConnectedAt $null
        $state = Read-VpnRuntimeState -StatePath $statePath

        $state.reason | Should Be 'Authentication/setup failure'
    }

    It 'extracts nested reason wrappers before english mapping' {
        $statePath = Join-Path $TestDrive 'vpn_state.json'

        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'running' -SessionState 'authenticating' -Reason 'detail: Reason=[openconnect][stderr] Unexpected 512 result from server; ExitCode=1' -ServicePid 1000 -OpenConnectPid 222 -ConnectedAt $null
        $state = Read-VpnRuntimeState -StatePath $statePath

        $state.reason | Should Be 'Authentication response was rejected by server (unexpected result 512).'
    }

    It 'normalizes last_disconnect_reason with bracket prefixes before english mapping' {
        $statePath = Join-Path $TestDrive 'vpn_state.json'

        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'running' -SessionState 'stopped' -Reason 'Session lost' -ServicePid 1000 -OpenConnectPid 0 -ConnectedAt $null -LastDisconnectReason '[openconnect][stderr] Unexpected 512 result from server'
        $state = Read-VpnRuntimeState -StatePath $statePath

        $state.last_disconnect_reason | Should Be 'Authentication response was rejected by server (unexpected result 512).'
    }

    It 'extracts wrapped last_disconnect_reason and normalizes localized content' {
        $statePath = Join-Path $TestDrive 'vpn_state.json'

        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'running' -SessionState 'stopped' -Reason 'Session lost' -ServicePid 1000 -OpenConnectPid 0 -ConnectedAt $null -LastDisconnectReason 'detail: Reason=認證失敗; ExitCode=1'
        $state = Read-VpnRuntimeState -StatePath $statePath

        $state.last_disconnect_reason | Should Be 'OpenConnect reported a localized or non-English event. Check vpn_openconnect_raw.log for details.'
    }
}
