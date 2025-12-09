# Interactive credential setup for VPN
# Run this script in a visible PowerShell window (double-click the .bat wrapper)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LibPath = Join-Path $ScriptDir 'lib\vpn_common.ps1'
if (Test-Path $LibPath) { . $LibPath }

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RootDir = (Resolve-Path (Join-Path $ScriptRoot '..')).ProviderPath
$WorkDir = $RootDir
$OpenConnectExe = "C:\Program Files\OpenConnect-GUI\openconnect.exe"
$Server = "vpn.ntut.edu.tw"
# Save credential to root `WorkDir` so service started from .bat finds it
$CredFile = Join-Path $WorkDir 'vpn_cred.xml'
$LogFile = Join-Path $WorkDir 'vpn_history.log'
$env:LOGFILE = $LogFile

function Test-VpnCredential {
    param(
        [Parameter(Mandatory = $true)] [string] $User,
        [Parameter(Mandatory = $true)] [string] $Password,
        [Parameter(Mandatory = $true)] [string] $Executable,
        [Parameter(Mandatory = $true)] [string] $Server,
        [int] $TimeoutSeconds = 20
    )

    if (-not (Test-Path $Executable)) {
        Write-Host "OpenConnect executable not found at $Executable" -ForegroundColor Red
        return $false
    }

    $plainPassword = $Password
    $ocArgs = @(
        '--protocol=gp',
        "--user=$User",
        '--passwd-on-stdin',
        '--authenticate',
        '--quiet',
        $Server
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.Arguments = ($ocArgs -join ' ')
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()
    $proc.StandardInput.WriteLine($plainPassword)
    $proc.StandardInput.Flush()
    $proc.StandardInput.Close()

    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch { }
        Write-Host "登入驗證逾時，請重新嘗試。" -ForegroundColor Red
        return $false
    }

    if ($proc.ExitCode -eq 0) {
        return $true
    }

    $errorOutput = $proc.StandardError.ReadToEnd()
    if ($errorOutput) {
        Write-Host $errorOutput.Trim()
    }

    return $false
}

Write-Host "VPN Credential Setup"

while ($true) {
    $User = Read-Host "Enter VPN username"
    $PlainPassword = Read-Host "Enter VPN password"

    Write-Host "驗證中，請稍候 ..." -ForegroundColor Cyan
    $isValid = Test-VpnCredential -User $User -Password $PlainPassword -Executable $OpenConnectExe -Server $Server

    if (-not $isValid) {
        Write-Host "登入失敗，請重新輸入帳號與密碼。" -ForegroundColor Red
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log ("Credential validation failed for user {0}" -f $User) }
        continue
    }

    # Convert plaintext password to SecureString and create credential
    $SecurePassword = ConvertTo-SecureString -String $PlainPassword -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($User, $SecurePassword)
    try {
        $cred | Export-Clixml -Path $CredFile
        Write-Host "Credential saved to $CredFile"
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log ("Saved credential for user {0} to {1}" -f $User, $CredFile) }
        break
    } catch {
        Write-Host "Failed to save credential: $_" -ForegroundColor Red
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log ("Failed to save credential: {0}" -f $_) }
    }
}

Write-Host "Setup complete. You can now run Start_VPN.bat to start the service (hidden)."
Start-Sleep -Seconds 2
