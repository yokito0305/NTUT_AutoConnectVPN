$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'src/Check_VPN_Status.ps1'
. $scriptPath

Describe 'Show-VpnStatus' {
    It 'prints disconnected state when no process is found' {
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Write-Host -MockWith { param([Parameter(ValueFromRemainingArguments = $true)] $Object) }

        Show-VpnStatus -ProcessName 'openconnect'

        Assert-MockCalled -CommandName Write-Host -ParameterFilter { $Object -eq ' o Disconnected' } -Times 1
    }
}
