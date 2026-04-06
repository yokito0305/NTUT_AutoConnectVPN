$repoRoot = Split-Path -Parent $PSScriptRoot
$libPath = Join-Path $repoRoot 'src/lib/vpn_common.ps1'
$scriptPath = Join-Path $repoRoot 'src/Stop_VPN_Logic.ps1'
. $libPath
. $scriptPath

Describe 'Invoke-StopVpnLogic' {
    It 'logs missing PID files gracefully' {
        $pidPath = Join-Path $TestDrive 'vpn_service.pid'
        $logPath = Join-Path $TestDrive 'vpn_history.log'
        Mock -CommandName Get-Process -MockWith { @() }

        Invoke-StopVpnLogic -PidPath $pidPath -LogPath $logPath

        $logContent = Get-Content -Path $logPath -Raw
        $logContent | Should Match 'PID file not found'
    }

    It 'stops the monitored process when PID file exists' {
        $pidPath = Join-Path $TestDrive 'vpn_service.pid'
        $logPath = Join-Path $TestDrive 'vpn_history.log'
        Set-Content -Path $pidPath -Value 1234
        Mock -CommandName Stop-Process {}
        Mock -CommandName Get-Process -MockWith { @() }

        Invoke-StopVpnLogic -PidPath $pidPath -LogPath $logPath

        Assert-MockCalled -CommandName Stop-Process -Times 1 -ParameterFilter { $Id -eq 1234 -and $Force -eq $true }
    }

    It 'clears the protective startup block even when no processes are running' {
        $pidPath = Join-Path $TestDrive 'vpn_service.pid'
        $logPath = Join-Path $TestDrive 'vpn_history.log'
        $statePath = Join-Path $TestDrive 'vpn_state.json'
        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'blocked' -SessionState 'stopped' -Reason 'Authentication/setup failure' -ServicePid 1000 -OpenConnectPid 0 -ConnectedAt $null -StartupBlocked $true -StartupBlockCategory 'auth_failure'
        Mock -CommandName Get-Process -MockWith { @() }

        Invoke-StopVpnLogic -PidPath $pidPath -LogPath $logPath -StatePath $statePath

        $state = Read-VpnRuntimeState -StatePath $statePath
        $state.startup_blocked | Should Be $false
        $state.reason | Should Match 'Stop_VPN'
    }

    It 'writes a stop request sentinel before resetting runtime state' {
        $pidPath = Join-Path $TestDrive 'vpn_service.pid'
        $logPath = Join-Path $TestDrive 'vpn_history.log'
        $statePath = Join-Path $TestDrive 'vpn_state.json'
        $stopRequestPath = Join-Path $TestDrive 'vpn_stop_requested.flag'
        Mock -CommandName Get-Process -MockWith { @() }

        Invoke-StopVpnLogic -PidPath $pidPath -LogPath $logPath -StatePath $statePath -StopRequestPath $stopRequestPath

        (Test-Path $stopRequestPath) | Should Be $true
    }

    It 'reverts only owned adapter-scoped DNS back to automatic on stop' {
        $pidPath = Join-Path $TestDrive 'vpn_service.pid'
        $logPath = Join-Path $TestDrive 'vpn_history.log'
        $statePath = Join-Path $TestDrive 'vpn_state.json'

        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'running' -SessionState 'connected' -Reason 'Connected' -ServicePid 1000 -OpenConnectPid 2000 -ConnectedAt (Get-Date) -NetworkConfigPlan ([pscustomobject]@{
            DnsTargetInterfaceIndex = 18
            DnsOwnedServers = @('140.124.13.1', '140.124.13.2')
            DnsPreexistingState = [pscustomobject]@{
                Mode = 'automatic_or_empty'
                ServerAddresses = @()
            }
        })

        Mock -CommandName Get-Process -MockWith { @() }
        Mock -CommandName Get-DnsClientServerAddress -MockWith {
            [pscustomobject]@{
                InterfaceIndex = 18
                ServerAddresses = @('140.124.13.1', '140.124.13.2')
            }
        }
        Mock -CommandName Set-DnsClientServerAddress {}

        Invoke-StopVpnLogic -PidPath $pidPath -LogPath $logPath -StatePath $statePath

        Assert-MockCalled -CommandName Set-DnsClientServerAddress -Times 1 -ParameterFilter { $InterfaceIndex -eq 18 -and $ResetServerAddresses -eq $true }
    }

    It 'reverts owned adapter-scoped DNS when current DNS still contains the owned session servers' {
        $pidPath = Join-Path $TestDrive 'vpn_service.pid'
        $logPath = Join-Path $TestDrive 'vpn_history.log'
        $statePath = Join-Path $TestDrive 'vpn_state.json'

        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'running' -SessionState 'connected' -Reason 'Connected' -ServicePid 1000 -OpenConnectPid 2000 -ConnectedAt (Get-Date) -NetworkConfigPlan ([pscustomobject]@{
            DnsTargetInterfaceIndex = 18
            DnsOwnedServers = @('140.124.13.1', '140.124.13.2')
            DnsPreexistingState = [pscustomobject]@{
                Mode = 'automatic_or_empty'
                ServerAddresses = @()
            }
        })

        Mock -CommandName Get-Process -MockWith { @() }
        Mock -CommandName Get-DnsClientServerAddress -MockWith {
            [pscustomobject]@{
                InterfaceIndex = 18
                ServerAddresses = @('140.124.13.1', '140.124.13.2', '8.8.8.8')
            }
        }
        Mock -CommandName Set-DnsClientServerAddress {}

        Invoke-StopVpnLogic -PidPath $pidPath -LogPath $logPath -StatePath $statePath

        Assert-MockCalled -CommandName Set-DnsClientServerAddress -Times 1 -ParameterFilter { $InterfaceIndex -eq 18 -and $ResetServerAddresses -eq $true }
    }

    It 'reverts only owned split routes on stop' {
        $pidPath = Join-Path $TestDrive 'vpn_service.pid'
        $logPath = Join-Path $TestDrive 'vpn_history.log'
        $statePath = Join-Path $TestDrive 'vpn_state.json'

        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'running' -SessionState 'connected' -Reason 'Connected' -ServicePid 1000 -OpenConnectPid 2000 -ConnectedAt (Get-Date) -NetworkConfigPlan ([pscustomobject]@{
            RouteOwnedEntries = @(
                [pscustomobject]@{
                    DestinationPrefix = '140.124.0.0/16'
                    InterfaceIndex = 18
                    NextHop = '0.0.0.0'
                }
            )
            DnsOwnedServers = @()
        })

        Mock -CommandName Get-Process -MockWith { @() }
        Mock -CommandName Get-NetRoute -MockWith {
            [pscustomobject]@{
                DestinationPrefix = '140.124.0.0/16'
                InterfaceIndex = 18
                NextHop = '0.0.0.0'
                RouteMetric = 1
            }
        }
        Mock -CommandName Remove-NetRoute {}

        Invoke-StopVpnLogic -PidPath $pidPath -LogPath $logPath -StatePath $statePath

        Assert-MockCalled -CommandName Remove-NetRoute -Times 1 -ParameterFilter { $DestinationPrefix -eq '140.124.0.0/16' -and $InterfaceIndex -eq 18 -and $NextHop -eq '0.0.0.0' }
    }

    It 'reverts owned include routes even when the active route next hop is represented differently' {
        $pidPath = Join-Path $TestDrive 'vpn_service.pid'
        $logPath = Join-Path $TestDrive 'vpn_history.log'
        $statePath = Join-Path $TestDrive 'vpn_state.json'

        Write-VpnRuntimeState -StatePath $statePath -ServiceState 'running' -SessionState 'connected' -Reason 'Connected' -ServicePid 1000 -OpenConnectPid 2000 -ConnectedAt (Get-Date) -NetworkConfigPlan ([pscustomobject]@{
            RouteOwnedEntries = @(
                [pscustomobject]@{
                    DestinationPrefix = '23.193.80.111/32'
                    InterfaceIndex = 62
                    NextHop = '0.0.0.0'
                    RouteType = 'include'
                }
            )
            DnsOwnedServers = @()
        })

        Mock -CommandName Get-Process -MockWith { @() }
        Mock -CommandName Get-NetRoute -MockWith {
            [pscustomobject]@{
                DestinationPrefix = '23.193.80.111/32'
                InterfaceIndex = 62
                NextHop = '23.193.80.111'
                RouteMetric = 1
            }
        }
        Mock -CommandName Remove-NetRoute {}

        Invoke-StopVpnLogic -PidPath $pidPath -LogPath $logPath -StatePath $statePath

        Assert-MockCalled -CommandName Remove-NetRoute -Times 1 -ParameterFilter { $DestinationPrefix -eq '23.193.80.111/32' -and $InterfaceIndex -eq 62 -and -not $PSBoundParameters.ContainsKey('NextHop') }
    }

    It 'defines Assert-Elevation and no longer invokes Ensure-Elevation directly' {
        $content = Get-Content $scriptPath -Raw

        $content | Should Match 'function Assert-Elevation'
        $content | Should Match 'Assert-Elevation'
        $content | Should Not Match 'Ensure-Elevation'
    }
}
