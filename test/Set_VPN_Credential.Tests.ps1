$repoRoot = Split-Path -Parent $PSScriptRoot

Describe 'Set_VPN_Credential script' {
    It 'exists and has Test-VpnCredential function defined' {
        $scriptPath = Join-Path $repoRoot 'src/Set_VPN_Credential.ps1'
        
        Test-Path $scriptPath | Should Be $true
        
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'function Test-VpnCredential'
    }

    It 'parses successfully as a PowerShell script' {
        $scriptPath = Join-Path $repoRoot 'src/Set_VPN_Credential.ps1'
        $content = Get-Content $scriptPath -Raw

        { [scriptblock]::Create($content) | Out-Null } | Should Not Throw
    }

    It 'exists and has Invoke-CredentialSetupLoop function defined' {
        $scriptPath = Join-Path $repoRoot 'src/Set_VPN_Credential.ps1'
        
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'function Invoke-CredentialSetupLoop'
    }

    It 'contains credential validation logic' {
        $scriptPath = Join-Path $repoRoot 'src/Set_VPN_Credential.ps1'
        
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'Test-VpnCredential'
        $content | Should Match 'Export-Clixml'
    }

    It 'loads shared openconnect session helpers for argument construction' {
        $scriptPath = Join-Path $repoRoot 'src/Set_VPN_Credential.ps1'

        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'openconnect_session\.ps1'
    }

    It 'builds credential validation arguments from Get-OpenConnectArguments' {
        $scriptPath = Join-Path $repoRoot 'src/Set_VPN_Credential.ps1'

        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'Get-OpenConnectArguments'
        $content | Should Match '--authenticate'
        $content | Should Match '--quiet'
    }
}
