# 載入共用函式（如果已存在於 src\lib）
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RootDir = (Resolve-Path (Join-Path $ScriptRoot '..')).ProviderPath
$LogFile = Join-Path $RootDir 'vpn_history.log'

function Import-VpnLibrary {
    param([string] $LogPath = $LogFile)

    try {
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

# 匯入憑證物件
$CredentialPath = Join-Path $RootDir 'vpn_cred.xml'
if (-not (Test-Path $CredentialPath)) {
    Write-Host "Credential file not found at $CredentialPath" -ForegroundColor Red
    return
}

$cred = Import-Clixml -Path $CredentialPath

# 顯示使用者名稱
Write-Host "Username: $($cred.UserName)"

# 方法 A：使用 vpn_common.ps1 中的 SecureStringToPlainText（如果已 dot-source）
if (Get-Command SecureStringToPlainText -ErrorAction SilentlyContinue) {
    $plain = SecureStringToPlainText $cred.Password
    Write-Host "Password: $plain"
    return
}

# 方法 B：直接用 Marshal 轉換（不需要外部函式）
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
try {
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    Write-Host "Password: $plain"
} finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
