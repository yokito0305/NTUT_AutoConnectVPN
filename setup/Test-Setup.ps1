# Test-Setup.ps1
# Verify AutoVPN setup completion

[CmdletBinding()]
param(
    [switch] $RunTests
)

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$ProjectRoot = (Resolve-Path (Join-Path $ScriptRoot '..')).ProviderPath

function Write-Check {
    param([string] $Item, [bool] $Pass, [string] $Message = '')
    $status = if ($Pass) { 'PASS' } else { 'FAIL' }
    $color = if ($Pass) { 'Green' } else { 'Red' }
    Write-Host "[$status] $Item" -ForegroundColor $color
}

function Test-ProjectStructure {
    Write-Host ""
    Write-Host "=== Project Structure ===" -ForegroundColor Cyan
    
    @(
        @{ Path = 'src'; Name = 'src directory' },
        @{ Path = 'test'; Name = 'test directory' },
        @{ Path = 'config'; Name = 'config directory' },
        @{ Path = 'config\config.ps1'; Name = 'Config file' },
        @{ Path = 'src\AutoVPN_Service.ps1'; Name = 'AutoVPN_Service.ps1' },
        @{ Path = 'src\lib\vpn_common.ps1'; Name = 'Common library' }
    ) | ForEach-Object {
        $fullPath = Join-Path $ProjectRoot $_.Path
        $exists = Test-Path $fullPath
        Write-Check $_.Name $exists
    }
}

function Test-BinDirectory {
    Write-Host ""
    Write-Host "=== OpenConnect Binary ===" -ForegroundColor Cyan
    
    $binPath = Join-Path $ProjectRoot 'bin'
    
    if (Test-Path $binPath) {
        Write-Check "bin directory exists" $true
        
        $exePath = Join-Path $binPath 'openconnect.exe'
        if (Test-Path $exePath) {
            Write-Check "openconnect.exe" $true
            Write-Host "  Path: $exePath" -ForegroundColor Gray
        }
        else {
            Write-Check "openconnect.exe" $false
            Write-Host "  Tip: Run Install-OpenConnect.ps1 to download" -ForegroundColor Yellow
        }
    }
    else {
        Write-Check "bin directory exists" $false
        Write-Host "  Tip: Run Install-OpenConnect.ps1 to download OpenConnect" -ForegroundColor Yellow
    }
}

function Test-Configuration {
    Write-Host ""
    Write-Host "=== Configuration ===" -ForegroundColor Cyan
    
    $configPath = Join-Path $ProjectRoot 'config\config.ps1'
    
    if (Test-Path $configPath) {
        Write-Check "Config file" $true
        
        try {
            . $configPath
            Write-Check "Config loads" $true
            Write-Host "  OpenConnect: $(Get-VpnConfig -ConfigKey 'OpenConnectExe')" -ForegroundColor Gray
            Write-Host "  VPN Server: $(Get-VpnConfig -ConfigKey 'VpnServer')" -ForegroundColor Gray
        }
        catch {
            Write-Check "Config loads" $false
        }
    }
    else {
        Write-Check "Config file" $false
    }
}

function Invoke-FullTest {
    Write-Host ""
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "         AutoVPN Setup Verification" -ForegroundColor Cyan
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Project root: $ProjectRoot" -ForegroundColor Gray
    
    Test-ProjectStructure
    Test-Configuration
    Test-BinDirectory
    
    Write-Host ""
    Write-Host "===============================================" -ForegroundColor Cyan
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-FullTest
}
