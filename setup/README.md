# Setup 指南

本目錄包含 AutoVPN 的自動化設置腳本。

## 快速開始

### 方法 1: 雙擊執行（推薦）

在 Windows 檔案管理器中雙擊：

```
setup\Start-Setup.bat
```

### 方法 2: PowerShell 命令列

```powershell
cd "C:\costum\path\AutoVPN\setup"
powershell -NoProfile -ExecutionPolicy Bypass -File "Invoke-Setup.ps1"
```

### 方法 3: 指定自訂 GitHub Repository

如果您維護自己的 OpenConnect 編譯版本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "Invoke-Setup.ps1" -GitHubRepo "your-username/your-repo"
```

## 腳本說明

### 1. Invoke-Setup.ps1（主設置腳本）

**用途**: 自動下載 OpenConnect 編譯版本並驗證配置

**執行流程**:
1. 檢查 PowerShell 版本 (需要 5.1+)
2. 從 GitHub Release 下載 OpenConnect-Standalone-Win64.zip
3. 解壓縮到 `./bin/` 目錄
4. 驗證 config.ps1 配置檔案
5. 顯示安裝狀態和後續步驟

**參數**:
- `-SkipOpenConnect` - 跳過 OpenConnect 下載，僅驗證完整性
- `-GitHubRepo` - 指定 GitHub Repository (預設: yokito0305/NTUT_AutoConnectVPN)

**範例**:
```powershell
# 完整安裝
. .\Invoke-Setup.ps1

# 跳過下載，僅驗證完整性
. .\Invoke-Setup.ps1 -SkipOpenConnect

# 使用自訂 Repository
. .\Invoke-Setup.ps1 -GitHubRepo "your-user/your-repo"
```

### 2. Start-Setup.bat（Windows 啟動器）

**用途**: 簡化 Windows 使用者的安裝流程

**使用方式**: 直接在檔案管理器中雙擊此檔案

### 3. Test-Setup.ps1（驗證腳本）

**用途**: 驗證 AutoVPN 設置是否完成

**使用方式**:
```powershell
# 檢查設置狀態
. .\Test-Setup.ps1

# 執行完整檢查並運行單元測試
. .\Test-Setup.ps1 -RunTests
```
