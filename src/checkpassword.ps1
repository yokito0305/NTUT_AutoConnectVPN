# 載入共用函式（如果已存在於 src\lib）
. .\src\lib\vpn_common.ps1

# 匯入憑證物件
$cred = Import-Clixml -Path .\vpn_cred.xml

# 顯示使用者名稱
Write-Host "Username: $($cred.UserName)"

# 方法 A：使用 vpn_common.ps1 中的 SecureStringToPlainText（如果已 dot-source）
if (Get-Command SecureStringToPlainText -ErrorAction SilentlyContinue) {
    $plain = SecureStringToPlainText $cred.Password
    Write-Host "Password: $plain"
} else {
    # 方法 B：直接用 Marshal 轉換（不需要外部函式）
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        Write-Host "Password: $plain"
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}