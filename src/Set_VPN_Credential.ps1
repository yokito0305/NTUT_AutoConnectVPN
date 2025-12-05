# Interactive credential setup for VPN
# Run this script in a visible PowerShell window (double-click the .bat wrapper)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LibPath = Join-Path $ScriptDir 'lib\vpn_common.ps1'
if (Test-Path $LibPath) { . $LibPath }

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RootDir = (Resolve-Path (Join-Path $ScriptRoot '..')).ProviderPath
$WorkDir = $RootDir
# Save credential to root `WorkDir` so service started from .bat finds it
$CredFile = Join-Path $WorkDir 'vpn_cred.xml'
$LogFile = Join-Path $WorkDir 'vpn_history.log'
$env:LOGFILE = $LogFile

Write-Host "VPN Credential Setup"

$User = Read-Host "Enter VPN username"
$Password = Read-Host -AsSecureString "Enter VPN password"
$cred = New-Object System.Management.Automation.PSCredential ($User, $Password)
try {
    $cred | Export-Clixml -Path $CredFile
    Write-Host "Credential saved to $CredFile"
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log ("Saved credential for user {0} to {1}" -f $User, $CredFile) }
} catch {
    Write-Host "Failed to save credential: $_"
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log ("Failed to save credential: {0}" -f $_) }
}

Write-Host "Setup complete. You can now run Start_VPN.bat to start the service (hidden)."
Start-Sleep -Seconds 2
