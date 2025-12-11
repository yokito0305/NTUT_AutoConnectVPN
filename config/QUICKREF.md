# 配置快速參考

快速查看和修改 AutoVPN 配置。

## 當前配置值

執行以下命令查看所有當前配置：

```powershell
cd ".\AutoVPN"
. .\config\config.ps1

# 顯示所有配置
@(
    'OpenConnectExe',
    'VpnServer',
    'VpnProtocol',
    'ReconnectDelay',
    'ProcessTerminationDelay',
    'PidFile',
    'LogFile',
    'CredentialFile'
) | ForEach-Object {
    $value = Get-VpnConfig -ConfigKey $_
    Write-Host "$_`: $value"
}
```

## 常用配置修改

### 1. 更改 VPN 伺服器

編輯 `config/config.ps1` 第 8 行：

```powershell
# 修改前
$global:Config_VpnServer = "vpn.ntut.edu.tw"

# 修改後
$global:Config_VpnServer = "your-vpn-server.com"
```

### 2. 更改 OpenConnect 路徑

編輯 `config/config.ps1` 第 4 行：

```powershell
# 修改前
$global:Config_OpenConnectExe = "C:\Program Files\OpenConnect-GUI\openconnect.exe"

# 修改後
$global:Config_OpenConnectExe = "D:\Tools\openconnect\openconnect.exe"
```

### 3. 調整重連延遲

編輯 `config/config.ps1` 第 25 行（從秒數調整）：

```powershell
# 修改前（10 秒）
$global:Config_ReconnectDelaySeconds = 10

# 修改後（30 秒）
$global:Config_ReconnectDelaySeconds = 30
```

### 4. 更改 VPN 協議

編輯 `config/config.ps1` 第 13 行：

```powershell
# 修改前（GlobalProtect）
$global:Config_VpnProtocol = "gp"

# 修改後（Cisco AnyConnect）
$global:Config_VpnProtocol = "anyconnect"
```

## 驗證配置修改

修改後執行以下命令驗證：

```powershell
cd "d:\Program Files\AutoVPN"
powershell -NoProfile -Command @"
. .\config\config.ps1
if (Test-VpnConfig) {
    Write-Host "✓ 配置有效" -ForegroundColor Green
} else {
    Write-Host "✗ 配置存在問題" -ForegroundColor Red
}
"@
```

## 配置參考表

| 配置項 | 變數名稱 | 預設值 | 說明 |
|-------|---------|-------|------|
| OpenConnect 路徑 | `Config_OpenConnectExe` | `C:\Program Files\OpenConnect-GUI\openconnect.exe` | OpenConnect 可執行檔位置 |
| VPN 伺服器 | `Config_VpnServer` | `vpn.ntut.edu.tw` | 目標 VPN 伺服器 |
| VPN 協議 | `Config_VpnProtocol` | `gp` | GlobalProtect(`gp`) 或 AnyConnect(`anyconnect`) |
| PID 檔案 | `Config_PidFileName` | `vpn_service.pid` | 服務進程 ID 檔案 |
| 日誌檔案 | `Config_LogFileName` | `vpn_history.log` | 連接日誌檔案 |
| 認證檔案 | `Config_CredentialFileName` | `vpn_cred.xml` | VPN 認證檔案 |
| 重連延遲 | `Config_ReconnectDelaySeconds` | `10` | 重連前等待秒數 |
| 進程終止延遲 | `Config_ProcessTerminationDelaySeconds` | `2` | 進程終止後等待秒數 |

## 配置檔案結構

```powershell
# 配置/config.ps1 檔案結構

# === OpenConnect Executable Path ===
$global:Config_OpenConnectExe = "..."

# === VPN Server Configuration ===
$global:Config_VpnServer = "..."

# === VPN Protocol ===
$global:Config_VpnProtocol = "gp"

# === File Paths ===
$global:Config_PidFileName = "vpn_service.pid"
$global:Config_LogFileName = "vpn_history.log"
$global:Config_CredentialFileName = "vpn_cred.xml"

# === Reconnection Settings ===
$global:Config_ReconnectDelaySeconds = 10

# === Process Cleanup ===
$global:Config_ProcessTerminationDelaySeconds = 2

# === Function to get full paths ===
function Get-VpnConfig { ... }

# === Validation Function ===
function Test-VpnConfig { ... }
```

## 故障排除

### 配置檔案未找到

**錯誤**: `Error: configuration file not found at ...`

**解決方案**: 確保 `config/config.ps1` 檔案存在於 AutoVPN 根目錄下。

### OpenConnect 路徑不存在

**錯誤**: `OpenConnect executable not found at: ...`

**解決方案**: 驗證 `Config_OpenConnectExe` 中的路徑是否正確。使用以下命令檢查：

```powershell
Test-Path "C:\Program Files\OpenConnect-GUI\openconnect.exe"
```

### 設定後仍無法連接

**步驟**:
1. 執行 `Test-VpnConfig` 驗證配置
2. 檢查 `vpn_history.log` 日誌檔案以查看詳細錯誤
3. 執行 `Set_VPN_Credential.ps1` 重新驗證認證

## 支援的 VPN 協議

OpenConnect 支持多種 VPN 協議。常用的有：

| 協議代碼 | 協議名稱 | 說明 |
|---------|---------|------|
| `gp` | GlobalProtect | Palo Alto Networks VPN（最常見） |
| `anyconnect` | Cisco AnyConnect | Cisco 企業 VPN |
| `openconnect` | OpenConnect | OpenConnect 原生協議 |
| `f5` | F5 BIG-IP | F5 的 VPN 解決方案 |
| `pulse` | Juniper Pulse | Juniper VPN |

根據您的 VPN 伺服器類型選擇相應的協議。

## 備份配置

為了安全起見，建議備份配置檔案：

```powershell
# 建立備份
Copy-Item "d:\Program Files\AutoVPN\config\config.ps1" "d:\Program Files\AutoVPN\config\config.ps1.backup"

# 還原備份
Copy-Item "d:\Program Files\AutoVPN\config\config.ps1.backup" "d:\Program Files\AutoVPN\config\config.ps1"
```
