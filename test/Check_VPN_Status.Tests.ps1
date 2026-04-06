$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'src/Check_VPN_Status.ps1'
. $scriptPath

Describe 'Get-VpnStatusModel' {
    It 'reports disconnected when no authoritative state file exists' {
        $status = Get-VpnStatusModel -StatePath (Join-Path $TestDrive 'missing-state.json')

        $status.SessionState | Should Be 'stopped'
        $status.ServiceState | Should Be 'stopped'
        $status.Reason | Should Be 'No VPN service state file was found.'
    }

    It 'reports connected only when the runtime state says connected' {
        $statePath = Join-Path $TestDrive 'vpn_state.json'
        $now = Get-Date
        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'running' -SessionState 'connected' -Reason 'VPN tunnel established' -ServicePid 1000 -OpenConnectPid 222 -ConnectedAt $now.AddSeconds(-5) -AssignedIp '172.24.232.72' -SessionExpiresAt $now.AddHours(4) -Gateway '140.124.4.100' -TransportMode 'https_fallback' -TransportChangedAt $now.AddMinutes(-2) -LastTransportEvent 'https_fallback_active' -LastTransportEventAt $now.AddMinutes(-2) -LastRekeyAt $now.AddMinutes(-3) -LastHipCheckAt $now.AddMinutes(-3) -LastDpdOkAt $now.AddSeconds(-10)
        $status = Get-VpnStatusModel -StatePath $statePath
        $status.SessionState | Should Be 'connected'
        $status.OpenConnectPid | Should Be 222
        $status.AssignedIp | Should Be '172.24.232.72'
        $status.Gateway | Should Be '140.124.4.100'
        $status.TransportMode | Should Be 'https_fallback'
        $status.LastTransportEvent | Should Be 'https_fallback_active'
    }

    It 'keeps authenticating state from being reported as connected even if an openconnect process exists elsewhere' {
        $statePath = Join-Path $TestDrive 'vpn_state.json'
        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'running' -SessionState 'authenticating' -Reason 'X-Private-Pan-Globalprotect: auth-failed' -ServicePid 1000 -OpenConnectPid 333

        $status = Get-VpnStatusModel -StatePath $statePath
        $status.SessionState | Should Be 'authenticating'
        $status.Reason | Should Match 'auth-failed'
    }

    It 'surfaces blocked state when startup is protectively locked' {
        $statePath = Join-Path $TestDrive 'vpn_state.json'
        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'blocked' -SessionState 'stopped' -Reason 'Authentication/setup failure' -ServicePid 1000 -OpenConnectPid 0 -ConnectedAt $null -StartupBlocked $true -StartupBlockCategory 'auth_failure'

        $status = Get-VpnStatusModel -StatePath $statePath

        $status.StartupBlocked | Should Be $true
        $status.StartupBlockCategory | Should Be 'auth_failure'
    }

    It 'falls back to network config plan values when top-level assigned ip and gateway are null' {
        $statePath = Join-Path $TestDrive 'vpn_state.json'
        $plan = [pscustomobject]@{
            AssignedIp = '172.24.232.41'
            Gateway = '140.124.4.100'
        }

        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'running' -SessionState 'connected' -Reason 'VPN tunnel established' -ServicePid 1000 -OpenConnectPid 222 -ConnectedAt (Get-Date) -AssignedIp $null -Gateway $null -NetworkConfigPlan $plan

        $status = Get-VpnStatusModel -StatePath $statePath

        $status.AssignedIp | Should Be '172.24.232.41'
        $status.Gateway | Should Be '140.124.4.100'
    }
}
