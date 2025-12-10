$repoRoot = Split-Path -Parent $PSScriptRoot
$autoScript = Join-Path $repoRoot 'src/AutoVPN_Service.ps1'
. $autoScript

Describe 'AutoVPN_Service credential handling' {
    It 'returns null when no credential candidate exists' {
        $result = Load-Credential -Candidates @('C:/nonexistent/path.xml')

        $result | Should -Be $null
    }

    It 'imports the first available credential file' {
        $credentialPath = Join-Path $TestDrive 'vpn_cred.xml'
        $cred = New-Object System.Management.Automation.PSCredential ('userA', (ConvertTo-SecureString -String 'secret' -AsPlainText -Force))
        $cred | Export-Clixml -Path $credentialPath

        $result = Load-Credential -Candidates @('C:/missing/first.xml', $credentialPath)

        $result.Path | Should -Be $credentialPath
        $result.Credential.UserName | Should -Be 'userA'
    }
}
