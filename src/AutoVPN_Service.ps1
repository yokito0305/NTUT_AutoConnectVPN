# Original location: D:\Program Files\script\src\AutoVPN_Service.ps1

param(
    [switch] $AlreadyElevated
)

function Test-IsAdministrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Elevation {
    param(
        [switch] $HiddenWindow
    )

    if (Test-IsAdministrator) { return }

    if ($AlreadyElevated) {
        Write-Host "Elevation requested but administrative privileges were not granted." -ForegroundColor Red
        exit 1
    }

    $windowStyle = if ($HiddenWindow) { 'Hidden' } else { 'Normal' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-AlreadyElevated')
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle $windowStyle -ArgumentList $argList
    exit
}

# Elevate once when launched directly; keep background hidden by default
if ($MyInvocation.InvocationName -ne '.') {
    Ensure-Elevation -HiddenWindow
}

# --- Configuration ---
# Determine project root (parent of this script's folder) so scripts are relocatable
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RootDir = (Resolve-Path (Join-Path $ScriptRoot '..')).ProviderPath
$WorkDir = $RootDir

# Load configuration
$ConfigPath = Join-Path $RootDir 'config\config.ps1'
if (Test-Path $ConfigPath) {
    . $ConfigPath
} else {
    Write-Host "Error: configuration file not found at $ConfigPath"
    exit 1
}

# Get configuration values
$OpenConnectExe = Get-VpnConfig -ConfigKey 'OpenConnectExe' -RootDir $RootDir
$Server = Get-VpnConfig -ConfigKey 'VpnServer' -RootDir $RootDir
$PidFile = Get-VpnConfig -ConfigKey 'PidFile' -RootDir $RootDir
$LogFile = Get-VpnConfig -ConfigKey 'LogFile' -RootDir $RootDir
$Protocol = Get-VpnConfig -ConfigKey 'VpnProtocol' -RootDir $RootDir

# Validate configuration
if (-not (Test-VpnConfig)) {
    exit 1
}

# --- Shared helpers (dot-source library) ---
# Set environment before dot-sourcing
$env:LOGFILE = $LogFile

# Load shared functions from library
$LibPath = Join-Path $ScriptRoot 'lib\vpn_common.ps1'
if (Test-Path $LibPath) {
    . $LibPath
} else {
    Write-Host "Error: lib not found at $LibPath"
    exit 1
}

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
        [string] $TargetServer,
        [string] $Protocol = 'gp'
    )

    $ocArgs = @(
        "--protocol=$Protocol",
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
        [string] $PidPath,
        [string] $Protocol = 'gp'
    )

    Write-Log "Attempting to connect to $TargetServer ..."

    # Clean up any existing OpenConnect processes to ensure single instance
    $existingProcesses = @(Get-Process 'openconnect' -ErrorAction SilentlyContinue)
    if ($existingProcesses.Count -gt 0) {
        Write-Log ("Cleaning up {0} existing OpenConnect process(es) before new connection" -f $existingProcesses.Count)
        foreach ($p in $existingProcesses) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
            } catch {
                Write-Log ("Failed to stop existing process (PID {0}): {1}" -f $p.Id, $_)
            }
        }
        Start-Sleep -Seconds 2  # Give time for processes to fully terminate
    }

    try {
        $startResult = Start-OpenConnect -Executable $Executable -Username $Username -TargetServer $TargetServer -Protocol $Protocol
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
        Write-Host "VPN Connection Lost - Attempting to reconnect..." -ForegroundColor Yellow
        
        # Clean up any remaining OpenConnect processes before retry
        $orphanedProcesses = @(Get-Process 'openconnect' -ErrorAction SilentlyContinue)
        if ($orphanedProcesses.Count -gt 0) {
            Write-Log ("Cleaning up {0} orphaned OpenConnect process(es)" -f $orphanedProcesses.Count)
            foreach ($p in $orphanedProcesses) {
                try {
                    Stop-Process -Id $p.Id -Force -ErrorAction Stop
                } catch {
                    Write-Log ("Failed to stop orphaned process (PID {0}): {1}" -f $p.Id, $_)
                }
            }
        }
    }
    catch {
        Write-Log ("Exception while starting OpenConnect: {0}" -f $_)
    }
}

function Start-VpnService {
    $SetCredScript = Join-Path $ScriptRoot 'Set_VPN_Credential.ps1'
    $StatusScript = Join-Path $ScriptRoot 'Check_VPN_Status.ps1'

    # Check if service is already running
    if (Test-Path $PidFile) {
        $ExistingPid = Get-Content $PidFile -ErrorAction SilentlyContinue
        if ($ExistingPid -and (Get-Process -Id $ExistingPid -ErrorAction SilentlyContinue)) {
            Write-Log "VPN monitor service is already running (PID: $ExistingPid)"
            Write-Host "VPN monitor service is already running (PID: $ExistingPid). Exiting." -ForegroundColor Yellow
            exit 0
        } else {
            Write-Log "Stale PID file found (PID: $ExistingPid). Cleaning up."
            Remove-Item $PidFile -ErrorAction SilentlyContinue
        }
    }

    Set-WorkingContext -PidPath $PidFile -WorkingDirectory $WorkDir
    Write-Log "=== VPN monitor started (Service PID: $PID) ==="
    Write-Host "VPN Monitor Service Started" -ForegroundColor Green
    Write-Host "Note: VPN connections may be interrupted every 4 hours by the server." -ForegroundColor Yellow
    Write-Host "      The service will automatically reconnect within 5 seconds." -ForegroundColor Yellow
    Write-Host ""

    $CredCandidates = @((Join-Path $ScriptRoot 'vpn_cred.xml'), (Join-Path $WorkDir 'vpn_cred.xml'))
    $CredData = Get-CredentialData -Candidates $CredCandidates -SetupScript $SetCredScript

    if (-not $CredData) {
        Write-Host "Credential setup did not complete successfully. Service will exit." -ForegroundColor Yellow
        exit
    }

    $credential = $CredData.Credential
    $User = $credential.UserName
    $Password = SecureStringToPlainText $credential.Password

    $ReconnectDelay = Get-VpnConfig -ConfigKey 'ReconnectDelay' -RootDir $RootDir

    while ($true) {
        Monitor-OpenConnect -Executable $OpenConnectExe -Username $User -Password $Password -TargetServer $Server -StatusScript $StatusScript -PidPath $PidFile -Protocol $Protocol
        Write-Log "Will retry connection in $ReconnectDelay seconds..."
        Write-Host "Reconnecting in $ReconnectDelay seconds..." -ForegroundColor Cyan
        Start-Sleep -Seconds $ReconnectDelay
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-VpnService
}
