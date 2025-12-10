$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'src/Set_VPN_Credential.ps1'
. $scriptPath

Describe 'Test-VpnCredential' {
    It 'returns false when executable is missing' {
        Mock -CommandName Test-Path -MockWith { $false }

        $result = Test-VpnCredential -User 'user' -Password 'pw' -Executable 'C:/missing.exe' -Server 'example.com'

        $result | Should -BeFalse
    }
}
