# 妾旀鍚嶇ū: D:\Program Files\script\src\AutoVPN_Service.ps1

# --- Configuration ---
# Determine project root (parent of this script's folder) so scripts are relocatable
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RootDir = (Resolve-Path (Join-Path $ScriptRoot '..')).ProviderPath
$WorkDir = $RootDir
$OpenConnectExe = "C:\Program Files\OpenConnect-GUI\openconnect.exe"

# VPN Info
$Server = "vpn.ntut.edu.tw"
$PidFile      = Join-Path $WorkDir "vpn_service.pid"
$LogFile      = Join-Path $WorkDir "vpn_history.log"

# --- Shared helpers (dot-source library) ---
# dot-source the shared library (vpn_common.ps1) located in lib\
try {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

    # Ensure writers know where to write
    $env:LOGFILE = $LogFile

    $LibPath = Join-Path $ScriptDir 'lib\vpn_common.ps1'
    if (Test-Path $LibPath) { . $LibPath } else { Write-Host "Warning: lib not found: $LibPath" }
} catch {
    Write-Host "Failed to load lib: $_"
}

# --- Initialization ---
# 1. 瀵叆 PID
$PID | Out-File -FilePath $PidFile -Force

# 2. 瑷畾鐩寗
Set-Location $WorkDir

Write-Log "=== VPN monitor started (Service PID: $PID) ==="

$SetCredScript = Join-Path $ScriptDir 'Set_VPN_Credential.ps1'

function Invoke-CredentialSetup {
    param([Parameter(Mandatory = $true)] [string] $SetupScript)

    if (-not (Test-Path $SetupScript)) {
        Write-Log ("Credential setup script missing: {0}" -f $SetupScript)
        Write-Host "Credential setup script not found: $SetupScript" -ForegroundColor Red
        exit
    }

    Write-Log ("Launching credential setup: {0}" -f $SetupScript)
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$SetupScript`"" -Wait -WindowStyle Normal
}

function Load-Credential {
    param([Parameter(Mandatory = $true)] [string[]] $Candidates)

    $credPath = $Candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $credPath) { return $null }

    try {
        $cred = Import-Clixml -Path $credPath
        if ($cred -is [System.Management.Automation.PSCredential]) {
            return @{ Path = $credPath; Credential = $cred }
        }
        Write-Log "Imported credential was not a PSCredential object."
    } catch {
        Write-Log ("Failed to import credential file {0}: {1}" -f $credPath, $_)
    }

    return $null
}

# Credential handling: prefer credential in the script folder, fall back to $WorkDir
$CredCandidates = @((Join-Path $ScriptDir 'vpn_cred.xml'), (Join-Path $WorkDir 'vpn_cred.xml'))
$CredData = Load-Credential -Candidates $CredCandidates

if (-not $CredData) {
    Write-Log "No valid credential found. Triggering interactive setup."
    Invoke-CredentialSetup -SetupScript $SetCredScript
    $CredData = Load-Credential -Candidates $CredCandidates
}

if (-not $CredData) {
    Write-Host "Credential setup did not complete successfully. Service will exit." -ForegroundColor Yellow
    exit
}

$CredFile = $CredData.Path
$credential = $CredData.Credential
$User = $credential.UserName
$Password = SecureStringToPlainText $credential.Password

# --- Main Loop ---
while ($true) {
    Write-Log "Attempting to connect to $Server ..."
    
    try {
        # 鍟熷嫊 OpenConnect
        # 浣跨敤鍙冩暩闄ｅ垪閬垮厤琛岀簩琛?(backtick) 灏庤嚧瑾炴硶鍟忛
        $ocArgs = @(
            '--protocol=gp',
            "--user=$User",
            '--passwd-on-stdin',
            $Server
        )
        # Start OpenConnect using .NET Process so we can feed password to stdin
        $argString = $ocArgs -join ' '
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $OpenConnectExe
        $psi.Arguments = $argString
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $false
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $started = $proc.Start()
        if ($started) {
            Write-Log ("Started OpenConnect (PID: {0})" -f $proc.Id)
            # send password to stdin
            try {
                $proc.StandardInput.WriteLine($Password)
                $proc.StandardInput.Flush()
                $proc.StandardInput.Close()
            } catch {
                Write-Log ("Failed to write password to OpenConnect stdin: {0}" -f $_)
            }

            # brief wait then check if process is still running -> likely connected
            Start-Sleep -Seconds 3
            if (-not $proc.HasExited) {
                Write-Log ("Connected: OpenConnect running (PID: {0})" -f $proc.Id)
            } else {
                Write-Log ("OpenConnect exited immediately (ExitCode: {0})" -f $proc.ExitCode)
            }

            # wait for exit (blocks until disconnected)
            $proc.WaitForExit()
            Write-Log "Warning: OpenConnect process ended (connection lost)."
        } else {
            Write-Log "Failed to start OpenConnect process."
        }
    }
    catch {
        Write-Log ("Exception while starting OpenConnect: {0}" -f $_)
    }

    Write-Log "Will retry connection in 5 seconds..."
    Start-Sleep -Seconds 5
}
