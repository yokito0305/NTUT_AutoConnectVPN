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

    It 'converts secure strings back to plaintext' {
        $secure = ConvertTo-SecureString -String 'p@ssw0rd' -AsPlainText -Force

        $plain = SecureStringToPlainText $secure

        $plain | Should Be 'p@ssw0rd'
    }
}
