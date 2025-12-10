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
        $logContent | Should -Match 'PID file not found'
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
}
