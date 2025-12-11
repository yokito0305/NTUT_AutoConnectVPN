# AutoVPN GitHub CLI & 自動部署設置完整指南

## 概述

AutoVPN 現已支援從 GitHub Release 自動下載並安裝 OpenConnect 到本地 `bin/` 資料夾，無需系統全域安裝。

## 已建立的檔案

### setup/ 目錄中的腳本

| 檔案 | 用途 |
|------|------|
| **Invoke-AutoVpnSetup.ps1** | 一鍵完整自動部署（推薦） |
| **Setup-GitHubCLI.ps1** | 檢查並安裝 GitHub CLI |
| **Install-OpenConnect.ps1** | 從 GitHub Release 下載 OpenConnect |
| **Test-Setup.ps1** | 驗證安裝是否成功 |
| **Start-Setup.bat** | Windows BAT 啟動器 |
| **README.md** | 詳細說明文檔 |

### config/ 目錄更新

- **config.ps1** 已更新，自動優先使用 `bin/openconnect.exe`
- 若 bin/ 版本不存在，自動回退到系統安裝版本

## 快速開始

### 方法 1: 雙擊啟動（最簡單）

```
D:\Program Files\AutoVPN\setup\Start-Setup.bat
```

### 方法 2: PowerShell 一鍵安裝

```powershell
cd "D:\Program Files\AutoVPN\setup"
. .\Invoke-AutoVpnSetup.ps1
```

### 方法 3: 命令列執行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Program Files\AutoVPN\setup\Invoke-AutoVpnSetup.ps1"
```

## 執行流程

`Invoke-AutoVpnSetup.ps1` 會依序執行以下步驟：

```
1. 系統前置條件檢查
   ├─ PowerShell 版本 (需要 5.1+)
   ├─ 執行原則設定
   └─ 必需工具驗證

2. GitHub CLI 設置
   ├─ 檢查是否已安裝
   ├─ 若未安裝，嘗試使用 Winget/Chocolatey/直接下載安裝
   └─ 驗證安裝成功

3. OpenConnect 安裝
   ├─ 從 GitHub Release 查詢最新版本
   ├─ 下載並解壓縮
   ├─ 驗證完整性（DLL 檔案等）
   └─ 自動更新 config.ps1 中的路徑

4. 配置驗證
   ├─ 載入 config.ps1
   ├─ 驗證所有設定項
   └─ 測試 OpenConnect 是否可執行

5. 單元測試
   ├─ 執行 Pester 測試套件
   └─ 驗證所有功能正常

6. 部署總結
   └─ 顯示檢查清單和後續步驟
```

## 配置檔案自動更新

安裝完成後，`config/config.ps1` 會自動更新為：

### 原始配置
```powershell
$global:Config_OpenConnectExe = "C:\Program Files\OpenConnect-GUI\openconnect.exe"
```

### 更新後（支援雙路徑）
```powershell
$BinOpenConnectExe = Join-Path $RootDir 'bin\openconnect.exe'
$SystemOpenConnectExe = "C:\Program Files\OpenConnect-GUI\openconnect.exe"

$global:Config_OpenConnectExe = if (Test-Path $BinOpenConnectExe) { 
    $BinOpenConnectExe 
} else { 
    $SystemOpenConnectExe 
}
```

**優先順序**：
1. 本地 `bin/openconnect.exe` (若存在)
2. 系統全域安裝 (若本地版本不存在)

## GitHub CLI 安裝方式（優先順序）

如果 GitHub CLI 未安裝，`Setup-GitHubCLI.ps1` 會嘗試以下方式：

### 1️⃣ Winget (Windows 11 內建)
```powershell
winget install --id GitHub.CLI --exact --accept-source-agreements
```

### 2️⃣ Chocolatey
```powershell
choco install gh -y
```

### 3️⃣ 直接從 GitHub Release 下載
- 自動下載最新版本
- 解壓縮到 `%ProgramFiles%\GitHub CLI`
- 自動新增到 PATH

## 驗證安裝

### 方法 1: 執行驗證腳本
```powershell
cd "D:\Program Files\AutoVPN\setup"
. .\Test-Setup.ps1
```

### 方法 2: 手動驗證
```powershell
# 驗證 OpenConnect 版本
D:\Program Files\AutoVPN\bin\openconnect.exe --version

# 驗證配置
cd D:\Program Files\AutoVPN
. .\config\config.ps1
Test-VpnConfig

# 執行單元測試
Invoke-Pester -Path ".\test\"
```

## 進階用法

### 強制重新安裝
```powershell
. .\Invoke-AutoVpnSetup.ps1 -Force
```

### 非互動模式（用於自動化部署）
```powershell
. .\Invoke-AutoVpnSetup.ps1 -NoInteractive
```

### 跳過 GitHub CLI 檢查
```powershell
. .\Invoke-AutoVpnSetup.ps1 -SkipGitHubCLI
```

### 僅安裝 OpenConnect
```powershell
cd "D:\Program Files\AutoVPN\setup"
. .\Install-OpenConnect.ps1 -BinPath "..\bin" -Validate
```

### 僅設置 GitHub CLI
```powershell
cd "D:\Program Files\AutoVPN\setup"
. .\Setup-GitHubCLI.ps1 -Force
```

## 檔案結構

安裝完成後的目錄結構：

```
AutoVPN/
├── bin/                          # OpenConnect 本地安裝
│   ├── openconnect.exe          # OpenConnect 主程式
│   ├── vpnc-script-win.js       # VPN 連接腳本
│   ├── libgnutls-30.dll         # 依賴 DLL
│   ├── libtasn1-6.dll
│   ├── libnettle-8.dll
│   └── ... (更多 DLL)
│
├── config/
│   ├── config.ps1               # 已更新，指向 bin/openconnect.exe
│   ├── README.md
│   └── QUICKREF.md
│
├── setup/
│   ├── Invoke-AutoVpnSetup.ps1  # 一鍵自動部署
│   ├── Setup-GitHubCLI.ps1      # GitHub CLI 設置
│   ├── Install-OpenConnect.ps1  # OpenConnect 安裝
│   ├── Test-Setup.ps1           # 驗證安裝
│   ├── Start-Setup.bat          # BAT 啟動器
│   └── README.md                # 詳細說明
│
├── src/
│   ├── AutoVPN_Service.ps1
│   ├── Set_VPN_Credential.ps1
│   ├── Check_VPN_Status.ps1
│   ├── Stop_VPN_Logic.ps1
│   └── lib/vpn_common.ps1
│
├── test/
│   ├── AutoVPN_Service.Tests.ps1
│   ├── Check_VPN_Status.Tests.ps1
│   ├── Set_VPN_Credential.Tests.ps1
│   ├── Stop_VPN_Logic.Tests.ps1
│   ├── VpnCommon.Tests.ps1
│   └── TEST_SUITE.md
│
└── ... (其他檔案)
```

## GitHub Release 結構

你的 GitHub 儲存庫自動化工作流程 (`.github/workflows/build_openconnectVPN.yml`) 會：

1. 從 GitLab 克隆 OpenConnect 源碼
2. 使用 MSYS2/MinGW64 編譯
3. 打包成 `OpenConnect-Standalone-Win64.zip`
4. 上傳到 GitHub Release

`Install-OpenConnect.ps1` 會自動從該 Release 下載最新版本。

## 故障排除

### 問題 1: GitHub API 限額
**症狀**：無法連接到 GitHub API

**解決方案**：
```powershell
# 設置 GitHub Token (可選，用於增加 API 限額)
$env:GITHUB_TOKEN = "your_github_token_here"
```

### 問題 2: PowerShell 執行原則
**症狀**：無法執行腳本

**解決方案**：
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

### 問題 3: 缺少 DLL 檔案
**症狀**：OpenConnect 執行時出錯

**解決方案**：
1. 重新執行 `Install-OpenConnect.ps1 -Force`
2. 驗證 `bin/` 目錄中是否有所有 `.dll` 檔案

### 問題 4: 下載失敗
**症狀**：無法從 GitHub 下載

**解決方案**：
1. 檢查網路連接：`ping github.com`
2. 檢查防火牆設定
3. 嘗試手動下載：https://github.com/yokito0305/NTUT_AutoConnectVPN/releases

## 後續步驟

設置完成後：

```powershell
cd D:\Program Files\AutoVPN

# 1. 設定 VPN 認證
. .\src\Set_VPN_Credential.ps1
Invoke-CredentialSetupLoop

# 2. 啟動 VPN 服務
. .\src\AutoVPN_Service.ps1

# 3. 查看 VPN 狀態
. .\src\Check_VPN_Status.ps1
```

## 或使用 BAT 檔案（更簡單）

```
Start_VPN.bat              # 啟動 VPN
Stop_VPN.bat               # 停止 VPN
Check_VPN.bat              # 查看狀態
Set_VPN_Credential.bat     # 設定認證
```

## 總結

✅ **已實現**：
- 自動從 GitHub Release 下載 OpenConnect
- GitHub CLI 自動安裝和設置
- 本地 `bin/` 目錄支援
- 配置自動路徑更新
- 一鍵自動部署流程
- 完整的驗證和測試
- 雙路徑支援（本地 + 系統全域）

🚀 **下一步**：
1. 在 GitHub 儲存庫上啟用自動化工作流程
2. 提交代碼並觸發編譯
3. 檢查 Release 頁面確認 artifacts 可用
4. 用戶只需執行 `Start-Setup.bat` 即可完成完整部署

## 支援和反饋

如遇到問題：
- 檢查日誌：`vpn_history.log`
- 執行驗證：`.\setup\Test-Setup.ps1`
- 提交 Issue：https://github.com/yokito0305/NTUT_AutoConnectVPN/issues
