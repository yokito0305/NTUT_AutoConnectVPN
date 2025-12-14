# AutoVPN 配置指南

本文檔說明 AutoVPN 系統的配置檔案結構與使用方式。

## 概述

AutoVPN 使用集中的配置檔案系統來管理所有 VPN 相關設定。所有設定值都集中在 `config/config.ps1` 中，確保配置的一致性和易於維護。

## 配置檔案位置

```
AutoVPN/
├── config/
│   ├── config.ps1          # 主配置檔案（必要）
│   └── README.md           # 本文檔
├── src/
│   ├── AutoVPN_Service.ps1
│   ├── Check_VPN_Status.ps1
│   ├── Set_VPN_Credential.ps1
│   ├── Stop_VPN_Logic.ps1
│   └── lib/
│       └── vpn_common.ps1
└── ...
```

## 配置項目說明

### 1. OpenConnect 可執行檔路徑

**變數名稱**: `$Config_OpenConnectExe`

**預設值**: `.\bin\openconnect.exe`

**說明**: OpenConnect 應用程式的完整路徑。如果您將 OpenConnect 安裝在不同位置，需要修改此值。

**範例**:
```powershell
$global:Config_OpenConnectExe = "C:\Custom\Path\openconnect.exe"
```

### 2. VPN 伺服器位址

**變數名稱**: `$Config_VpnServer`

**預設值**: `vpn.ntut.edu.tw`

**說明**: 要連接的 VPN 伺服器位址（域名或 IP）。

**範例**:
```powershell
$global:Config_VpnServer = "vpn.company.com"
```

### 3. VPN 協議

**變數名稱**: `$Config_VpnProtocol`

**預設值**: `gp`

**說明**: OpenConnect 使用的 VPN 協議。常見選項：
- `gp` - GlobalProtect（預設，適用於 Palo Alto Networks）
- `anyconnect` - Cisco AnyConnect
- `openconnect` - OpenConnect 原生協議

**範例**:
```powershell
$global:Config_VpnProtocol = "anyconnect"
```

### 4. 檔案名稱配置

#### PID 檔案名稱
**變數名稱**: `$Config_PidFileName`
**預設值**: `vpn_service.pid`
**說明**: 存儲服務進程 ID 的檔案名稱。

#### 日誌檔案名稱
**變數名稱**: `$Config_LogFileName`
**預設值**: `vpn_history.log`
**說明**: 存儲連接歷史和調試信息的日誌檔案名稱。

#### 認證檔案名稱
**變數名稱**: `$Config_CredentialFileName`
**預設值**: `vpn_cred.xml`
**說明**: 存儲加密 VPN 認證的檔案名稱。

### 5. 重新連接設定

**變數名稱**: `$Config_ReconnectDelaySeconds`

**預設值**: `5`

**說明**: VPN 斷開後等待多少秒再嘗試重新連接。VPN 伺服器通常每 4 小時強制斷開一次，建議可設置為 10 秒以避免頻繁重試。

**範例**:
```powershell
$global:Config_ReconnectDelaySeconds = 15  # 15 秒後重連
```

### 6. 進程終止延遲

**變數名稱**: `$Config_ProcessTerminationDelaySeconds`

**預設值**: `2`

**說明**: 強制終止 OpenConnect 進程後，等待多少秒以確保進程完全終止。增加此值可確保更可靠的進程清理。

## 使用配置

### 在腳本中載入配置

所有 AutoVPN 腳本都會自動載入配置檔案：

```powershell
# 1. 確定專案根目錄
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RootDir = (Resolve-Path (Join-Path $ScriptRoot '..')).ProviderPath

# 2. 載入配置
$ConfigPath = Join-Path $RootDir 'config\config.ps1'
if (Test-Path $ConfigPath) {
    . $ConfigPath
} else {
    Write-Host "Error: configuration file not found"
    exit 1
}

# 3. 取得配置值
$OpenConnectExe = Get-VpnConfig -ConfigKey 'OpenConnectExe' -RootDir $RootDir
$Server = Get-VpnConfig -ConfigKey 'VpnServer' -RootDir $RootDir
```

### Get-VpnConfig 函數

**用途**: 取得配置值的標準函數

**語法**:
```powershell
Get-VpnConfig -ConfigKey <string> [-RootDir <string>]
```

**參數**:
- `ConfigKey` (必要): 配置鍵名，支持的值：
  - `PidFile` - PID 檔案完整路徑
  - `LogFile` - 日誌檔案完整路徑
  - `CredentialFile` - 認證檔案完整路徑
  - `OpenConnectExe` - OpenConnect 可執行檔路徑
  - `VpnServer` - VPN 伺服器位址
  - `VpnProtocol` - VPN 協議
  - `ReconnectDelay` - 重連延遲（秒）
  - `ProcessTerminationDelay` - 進程終止延遲（秒）

- `RootDir` (可選): 專案根目錄。若未指定，將自動確定。

**範例**:
```powershell
$pidFile = Get-VpnConfig -ConfigKey 'PidFile'
$reconnectDelay = Get-VpnConfig -ConfigKey 'ReconnectDelay'
```

### Test-VpnConfig 函數

**用途**: 驗證配置的完整性和正確性

**語法**:
```powershell
Test-VpnConfig
```

**檢查項目**:
- OpenConnect 可執行檔是否存在
- VPN 伺服器位址是否已配置
- 重連延遲是否為正數

**返回值**:
- `$true` - 配置有效
- `$false` - 配置存在問題（錯誤信息會輸出到控制檯）

**範例**:
```powershell
if (-not (Test-VpnConfig)) {
    Write-Host "Configuration error detected"
    exit 1
}
```

## 配置修改指南

### 更改 VPN 伺服器

編輯 `config/config.ps1`：

```powershell
# 修改此行
$global:Config_VpnServer = "your-new-vpn-server.com"
```

### 更改 OpenConnect 路徑

如果 OpenConnect 安裝在自訂位置：

```powershell
$global:Config_OpenConnectExe = "D:\Tools\openconnect.exe"
```

### 調整重連延遲

減少重連等待時間（例如改為 5 秒）：

```powershell
$global:Config_ReconnectDelaySeconds = 5
```

### 變更認證儲存位置

修改認證檔案名稱（檔案仍會儲存在專案根目錄）：

```powershell
$global:Config_CredentialFileName = "my_vpn_credentials.xml"
```

## 環境變數依賴

配置系統依賴 `$env:LOGFILE` 環境變數來設定日誌輸出位置。所有腳本在載入配置後都會設置此變數：

```powershell
$env:LOGFILE = $LogFile
```

## 驗證配置

運行以下命令驗證配置是否正確：

```powershell
# 進入 AutoVPN 目錄
cd "d:\Program Files\AutoVPN"

# 載入並驗證配置
powershell -NoProfile -Command @"
. .\config\config.ps1
Test-VpnConfig
Write-Host "OpenConnect: $(Get-VpnConfig -ConfigKey 'OpenConnectExe')"
Write-Host "VPN Server: $(Get-VpnConfig -ConfigKey 'VpnServer')"
"@
```

## 常見問題

### Q: 如何在多台電腦上使用不同的 VPN 伺服器？

A: 在每台電腦上編輯 `config/config.ps1` 中的 `$Config_VpnServer` 即可。

### Q: 能否在執行時動態修改配置？

A: 可以。配置值存儲在全域變數中，可在運行時修改。但修改不會持久化到檔案，建議直接編輯 `config/config.ps1`。

### Q: 配置檔案的編碼要求是什麼？

A: 與其他腳本相同，應使用 **UTF-8 with BOM** 編碼以確保 PowerShell 5.1 正確解析。

### Q: 如果 OpenConnect 路徑不存在會怎樣？

A: `Test-VpnConfig` 會返回 `$false`，服務啟動時會自動退出並顯示錯誤信息。

## 所有腳本配置集成

下表顯示各腳本如何使用配置：

| 腳本 | 使用的配置項 | 目的 |
|------|-----------|------|
| `AutoVPN_Service.ps1` | OpenConnectExe, VpnServer, VpnProtocol, PidFile, LogFile, ReconnectDelay | 啟動和監控 VPN 連接 |
| `Check_VPN_Status.ps1` | LogFile | 顯示 VPN 連接狀態 |
| `Set_VPN_Credential.ps1` | OpenConnectExe, VpnServer, VpnProtocol, CredentialFile, LogFile | 驗證和儲存 VPN 認證 |
| `Stop_VPN_Logic.ps1` | PidFile, LogFile | 停止 VPN 服務 |

## 版本歷史

- **v1.0** (2025-12-11) - 初始配置系統實現
  - 集中式配置管理
  - 支持所有關鍵 VPN 參數
  - 配置驗證函數
  - 跨腳本統一配置載入
