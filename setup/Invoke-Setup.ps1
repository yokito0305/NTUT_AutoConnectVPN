# AutoVPN Setup Script
# Downloads compiled OpenConnect from GitHub and validates configuration

param(
    [switch] $SkipOpenConnect,
    [string] $GitHubRepo = "yokito0305/NTUT_AutoConnectVPN"
)

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$ProjectRoot = (Resolve-Path (Join-Path $ScriptRoot '..')).ProviderPath
$BinDir = Join-Path $ProjectRoot 'bin'
$OpenConnectInstalled = $false

Write-Host ""
Write-Host "==== AutoVPN Setup Script ====" -ForegroundColor Magenta
Write-Host ""

# Check PowerShell
Write-Host "PowerShell version: $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)" -ForegroundColor Cyan
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "ERROR: PowerShell 5.1+ required" -ForegroundColor Red
    exit 1
}

Write-Host "OK" -ForegroundColor Green

# Download OpenConnect from GitHub Release
Write-Host ""
Write-Host "OpenConnect binary..." -ForegroundColor Cyan

if ($SkipOpenConnect) {
    Write-Host "SKIPPED (--SkipOpenConnect)" -ForegroundColor Yellow
}
else {
    # Create bin directory if not exists
    if (-not (Test-Path $BinDir)) {
        New-Item -Path $BinDir -ItemType Directory -Force | Out-Null
        Write-Host "Created bin directory" -ForegroundColor Gray
    }

    # Check if openconnect.exe already exists
    $ocExePath = Join-Path $BinDir 'openconnect.exe'
    $OpenConnectInstalled = $false

    if (Test-Path $ocExePath) {
        Write-Host "Already installed at $ocExePath" -ForegroundColor Green
        $OpenConnectInstalled = $true
    }
    else {
        # Download latest release from GitHub
        try {
            Write-Host "Downloading OpenConnect from GitHub..." -ForegroundColor Cyan
            
            # Get latest release info
            $apiUrl = "https://api.github.com/repos/$GitHubRepo/releases/latest"
            $release = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop
            
            if (-not $release.assets) {
                Write-Host "No release assets found" -ForegroundColor Red
                Write-Host "Manual installation required" -ForegroundColor Yellow
                exit 1
            }
            else {
                # Find the specific OpenConnect binary package
                # We look for 'OpenConnect-Standalone-Win64.zip' specifically to avoid downloading source code or other assets
                $zipAsset = $release.assets | Where-Object { $_.name -match 'OpenConnect.*Win64.*\.zip' } | Select-Object -First 1
                
                if ($zipAsset) {
                    $downloadUrl = $zipAsset.browser_download_url
                    $tempZip = Join-Path $env:TEMP "openconnect-$([guid]::NewGuid().ToString().Substring(0,8)).zip"
                    
                    Write-Host "Downloading binary package: $($zipAsset.name)" -ForegroundColor Cyan
                    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip -ErrorAction Stop
                    
                    # Verify file size
                    $fileSize = (Get-Item $tempZip).Length
                    if ($fileSize -gt 1MB) {
                        Write-Host "Extracting to $BinDir..." -ForegroundColor Cyan
                        
                        # Clear existing bin directory content to avoid conflicts
                        Get-ChildItem -Path $BinDir -Recurse | Remove-Item -Force -Recurse
                        
                        # Extract ZIP
                        Expand-Archive -Path $tempZip -DestinationPath $BinDir -Force
                        
                        # Cleanup
                        Remove-Item $tempZip -Force
                        
                        # Verify extraction
                        if (Test-Path (Join-Path $BinDir 'openconnect.exe')) {
                            Write-Host "Installation successful!" -ForegroundColor Green
                            Write-Host "Installed to: $BinDir" -ForegroundColor Green

                            $OpenConnectInstalled = $true
                            
                            # List installed files count
                            $fileCount = (Get-ChildItem $BinDir).Count
                            Write-Host "Total files installed: $fileCount (EXE + DLLs + Scripts)" -ForegroundColor Gray
                        } else {
                            Write-Host "ERROR: Extraction failed, openconnect.exe not found" -ForegroundColor Red
                            exit 1
                        }
                    }
                    else {
                        Write-Host "ERROR: Downloaded file too small ($fileSize bytes)" -ForegroundColor Red
                        Remove-Item $tempZip -ErrorAction SilentlyContinue
                        exit 1
                    }
                }
                else {
                    Write-Host "No .zip package found in release assets" -ForegroundColor Yellow
                    Write-Host "Available assets: $($release.assets.name -join ', ')" -ForegroundColor Gray
                    Write-Host "Manual installation required" -ForegroundColor Yellow
                    exit 1
                }
            }
        }
        catch {
            Write-Host "ERROR: Failed to download - $_" -ForegroundColor Red
            Write-Host "Manual installation: https://github.com/$GitHubRepo/releases" -ForegroundColor Yellow
            Write-Host "Extract all files (EXE + DLLs) to: $BinDir" -ForegroundColor Yellow
            exit 1
        }
    }
}

if (-not $SkipOpenConnect -and -not $OpenConnectInstalled) {
    Write-Host "ERROR: OpenConnect was not installed. Please install manually and rerun setup." -ForegroundColor Red
    exit 1
}

# Check config
Write-Host ""
Write-Host "Configuration file..." -ForegroundColor Cyan
$configPath = Join-Path $ProjectRoot 'config\config.ps1'
if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: Not found" -ForegroundColor Red
    exit 1
}

try {
    . $configPath
    if (Test-VpnConfig) {
        Write-Host "OK - Config is valid" -ForegroundColor Green
    }
    else {
        Write-Host "ERROR: Config validation failed" -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}

# Show config
Write-Host ""
Write-Host "Current settings:" -ForegroundColor Cyan

$ocExePath = Join-Path $BinDir 'openconnect.exe'
if (Test-Path $ocExePath) {
    Write-Host "  OpenConnect: $ocExePath (INSTALLED)" -ForegroundColor Green
}
else {
    Write-Host "  OpenConnect: $ocExePath (NOT FOUND)" -ForegroundColor Yellow
}

Write-Host "  VPN Server: $(Get-VpnConfig -ConfigKey 'VpnServer')" -ForegroundColor Green
Write-Host "  Protocol: $(Get-VpnConfig -ConfigKey 'VpnProtocol')" -ForegroundColor Green
Write-Host "  Bin Directory: $BinDir" -ForegroundColor Cyan

Write-Host ""
Write-Host "Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan

if (-not (Test-Path (Join-Path $BinDir 'openconnect.exe'))) {
    Write-Host "  1. Download latest OpenConnect: https://github.com/$GitHubRepo/releases" -ForegroundColor Yellow
    Write-Host "     Extract to: $BinDir" -ForegroundColor Yellow
}
else {
    Write-Host "  1. OpenConnect is installed" -ForegroundColor Green
}

Write-Host "  2. Run Set_VPN_Credential.bat to setup VPN credentials"
Write-Host "  3. Run Start_VPN.bat to connect"
Write-Host ""

exit 0
