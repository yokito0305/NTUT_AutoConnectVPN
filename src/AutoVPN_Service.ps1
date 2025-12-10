# Original location: D:\Program Files\script\src\AutoVPN_Service.ps1

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
function Import-VpnLibrary {
    param(
        [string] $LogPath = $LogFile
    )

    try {
        # Ensure writers know where to write
        $env:LOGFILE = $LogPath

        $LibPath = Join-Path $ScriptRoot 'lib\vpn_common.ps1'
        if (Test-Path $LibPath) {
            . $LibPath
        } else {
            Write-Host "Warning: lib not found: $LibPath"
        }
    } catch {
        Write-Host "Failed to load lib: $_"
    }
}

Import-VpnLibrary

# --- Initialization helpers ---
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

function Get-CredentialData {
    param(
        [Parameter(Mandatory = $true)] [string[]] $Candidates,
        [Parameter(Mandatory = $true)] [string] $SetupScript
    )

    $credData = Load-Credential -Candidates $Candidates
    if ($credData) { return $credData }

    Write-Log "No valid credential found. Triggering interactive setup."
    Invoke-CredentialSetup -SetupScript $SetupScript
    return (Load-Credential -Candidates $Candidates)
}

function Set-WorkingContext {
    param(
        [string] $PidPath = $PidFile,
        [string] $WorkingDirectory = $WorkDir
    )

    $PID | Out-File -FilePath $PidPath -Force
    Set-Location $WorkingDirectory
}

function Show-StatusWindow {
    param([string] $StatusScript)

    if (Test-Path $StatusScript) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',"`"$StatusScript`"" -WindowStyle Normal
    }
}

# --- OpenConnect operations ---
function Start-OpenConnect {
    param(
        [string] $Executable,
        [string] $Username,
        [string] $TargetServer
    )

    $ocArgs = @(
        '--protocol=gp',
        "--user=$Username",
        '--passwd-on-stdin',
        $TargetServer
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.Arguments = ($ocArgs -join ' ')
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $false
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    [PSCustomObject]@{
        Process = $proc
        Started = $proc.Start()
    }
}

function Send-PasswordToProcess {
    param(
        [System.Diagnostics.Process] $Process,
        [string] $Password
    )

    try {
        $Process.StandardInput.WriteLine($Password)
        $Process.StandardInput.Flush()
        $Process.StandardInput.Close()
    } catch {
        Write-Log ("Failed to write password to OpenConnect stdin: {0}" -f $_)
    }
}

function Handle-ImmediateExit {
    param(
        [System.Diagnostics.Process] $Process,
        [string] $PidPath,
        [string] $StatusScript
    )

    Write-Log ("Authentication/login failed: OpenConnect exited immediately (ExitCode: {0})" -f $Process.ExitCode)
    Show-StatusWindow -StatusScript $StatusScript

    try {
        if (Test-Path $PidPath) {
            Remove-Item $PidPath -ErrorAction SilentlyContinue
            Write-Log ("Removed PID file: {0}" -f $PidPath)
        }
    } catch {
        Write-Log ("Failed to remove PID file: {0}" -f $_)
    }

    Write-Log "Service exiting due to authentication/login failure."
    exit 1
}

function Monitor-OpenConnect {
    param(
        [string] $Executable,
        [string] $Username,
        [string] $Password,
        [string] $TargetServer,
        [string] $StatusScript,
        [string] $PidPath
    )

    Write-Log "Attempting to connect to $TargetServer ..."

    try {
        $startResult = Start-OpenConnect -Executable $Executable -Username $Username -TargetServer $TargetServer
        if (-not $startResult.Started) {
            Write-Log "Failed to start OpenConnect process."
            return
        }

        $proc = $startResult.Process
        Write-Log ("Started OpenConnect (PID: {0})" -f $proc.Id)

        Send-PasswordToProcess -Process $proc -Password $Password

        Start-Sleep -Seconds 3
        if (-not $proc.HasExited) {
            Write-Log ("Connected: OpenConnect running (PID: {0})" -f $proc.Id)
            Show-StatusWindow -StatusScript $StatusScript
        } else {
            Handle-ImmediateExit -Process $proc -PidPath $PidPath -StatusScript $StatusScript
        }

        $proc.WaitForExit()
        Write-Log "Warning: OpenConnect process ended (connection lost)."
    }
    catch {
        Write-Log ("Exception while starting OpenConnect: {0}" -f $_)
    }
}

function Start-VpnService {
    $SetCredScript = Join-Path $ScriptRoot 'Set_VPN_Credential.ps1'
    $StatusScript = Join-Path $ScriptRoot 'Check_VPN_Status.ps1'

    Set-WorkingContext -PidPath $PidFile -WorkingDirectory $WorkDir
    Write-Log "=== VPN monitor started (Service PID: $PID) ==="

    $CredCandidates = @((Join-Path $ScriptRoot 'vpn_cred.xml'), (Join-Path $WorkDir 'vpn_cred.xml'))
    $CredData = Get-CredentialData -Candidates $CredCandidates -SetupScript $SetCredScript

    if (-not $CredData) {
        Write-Host "Credential setup did not complete successfully. Service will exit." -ForegroundColor Yellow
        exit
    }

    $credential = $CredData.Credential
    $User = $credential.UserName
    $Password = SecureStringToPlainText $credential.Password

    while ($true) {
        Monitor-OpenConnect -Executable $OpenConnectExe -Username $User -Password $Password -TargetServer $Server -StatusScript $StatusScript -PidPath $PidFile
        Write-Log "Will retry connection in 5 seconds..."
        Start-Sleep -Seconds 5
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-VpnService
}
