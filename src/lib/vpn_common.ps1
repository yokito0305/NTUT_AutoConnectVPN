# Shared helpers for VPN scripts
# - Write-Log: write timestamped lines to $LogFile (expects $LogFile variable set in caller)
# - Ensure-Credential: prompt once for password (for a given user) and save encrypted to file (Export-Clixml)

function Write-Log {
    param(
        [Parameter(Mandatory=$true)] [string] $Message,
        [string] $LogPath
    )
    if (-not $LogPath) { $LogPath = $env:LOGFILE }
    if (-not $LogPath) { return }
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "[$TimeStamp] $Message"
    # Ensure UTF8 without BOM for consistent appending across processes
    Add-Content -Path $LogPath -Value $LogLine -Encoding UTF8
}

function Ensure-Credential {
    param(
        [Parameter(Mandatory=$true)] [string] $CredFile,
        [Parameter(Mandatory=$true)] [string] $User
    )
    # Return a PSCredential. If $CredFile exists, import it; otherwise prompt for password and save.
    if (Test-Path $CredFile) {
        try {
            $cred = Import-Clixml -Path $CredFile
            if ($cred -is [System.Management.Automation.PSCredential]) { return $cred }
        } catch {
            # corrupted or unreadable, fall through to prompt
        }
    }

    # Prompt for password (silent) and save credential
    Write-Host "Enter password for user: $User"
    $pw = Read-Host -AsSecureString "Password" 
    $cred = New-Object System.Management.Automation.PSCredential ($User, $pw)
    try {
        $cred | Export-Clixml -Path $CredFile
        Write-Host "Credential saved to $CredFile (encrypted for this user)."
    } catch {
        Write-Host "Warning: failed to save credential: $_"
    }
    return $cred
}

function SecureStringToPlainText($secure) {
    if (-not $secure) { return '' }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# This file is intended for dot-sourcing (`. ./lib/vpn_common.ps1`).
# No module registration is required here.
