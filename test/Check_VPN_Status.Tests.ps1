$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'src/Check_VPN_Status.ps1'
. $scriptPath

Describe 'Show-VpnStatus' {
    It 'handles disconnected and connected states' {
        Mock -CommandName Get-Process -MockWith { @() }
        Mock -CommandName Clear-Host -MockWith { }
        
        # Verify function can be called without errors when disconnected
        Show-VpnStatus -ProcessName 'openconnect'
        
        Assert-MockCalled -CommandName Get-Process -Times 1
        Assert-MockCalled -CommandName Clear-Host -Times 1
    }

    It 'handles multiple OpenConnect processes' {
        $mockProc1 = New-Object PSObject -Property @{Id = 111; StartTime = [DateTime]::Now}
        $mockProc2 = New-Object PSObject -Property @{Id = 222; StartTime = [DateTime]::Now}
        Mock -CommandName Get-Process -MockWith { @($mockProc1, $mockProc2) }
        Mock -CommandName Clear-Host -MockWith { }
        
        Show-VpnStatus -ProcessName 'openconnect'
        
        Assert-MockCalled -CommandName Get-Process -Times 1
    }
}
