# AutoVPN 使用教學

本專案以 OpenConnect-GUI 取代 GlobalProtect，腳本已預設連線到 NTUT VPN Gateway，方便在 Windows 上快速連線。

## 安裝
1. 下載並執行 OpenConnect-GUI 安裝程式：<https://www.infradead.org/openconnect-gui/download/openconnect-gui-1.6.2-win64.exe>
2. 安裝過程的「選擇元件」頁面，請勾選 **console**，其他維持預設即可。
3. 安裝完成頁面請取消勾選「執行 OpenConnect-GUI」後再按「完成」。

## 初始設定（可選）

第一次使用建議執行 `Set_VPN_Credential.bat` 以儲存 VPN 帳號與密碼（產生的 `vpn_cred.xml` 僅能由同一使用者解密）。

也可以直接跳到「使用方式」執行 `Start_VPN.bat`，第一次登入時會自動執行初始化。

若 PowerShell 顯示執行原則限制，請先了解執行原則的選項與安全考量，並建議改為對當前使用者帳號永久（persistent）設定，而非只在單一 session 使用臨時允許。

簡要說明常見的執行原則（ExecutionPolicy）：
- `Restricted`: 預設（最嚴格），不允許執行任何腳本。
- `RemoteSigned`: 允許執行本機產生的腳本；從網路下載的腳本需有簽章。對開發與自用腳本來說是常見且較安全的選擇。
- `Unrestricted`: 允許執行所有腳本，會在執行從網路下載的腳本時提示風險。

查詢目前的執行原則（建議先檢查）：

```powershell
Get-ExecutionPolicy -List
```

推薦作法（對使用者帳號永久生效，無需每次開新 terminal 重複設定）：

```powershell
# Set for current user (no admin required)
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
```

說明與注意事項：
- `-Scope CurrentUser` 只會影響目前 Windows 使用者帳號，通常不需要管理員權限；若要對整台機器所有使用者套用，使用 `-Scope LocalMachine`（需要以系統管理員權限執行）。
- 若你在公司環境，執行原則可能受 Group Policy 管理，請先與資訊人員確認。
- 若你不想改變全域設定，也可以臨時在單一 session 使用：

```powershell
# 臨時允許只在目前 PowerShell 視窗生效（不會變更系統設定）
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
```

若要還原設定，可把執行原則改回 `Restricted`（或你原先的值）：

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Restricted -Force
```

要建立或更新憑證（互動式）：

```powershell
.\Set_VPN_Credential.bat
```

## 使用方式
批次檔可直接雙擊執行，以下範例也可在 PowerShell 或命令提示字元執行。

- 啟動 VPN：

```powershell
.\Start_VPN.bat
```

- 停止 VPN：

```powershell
.\Stop_VPN.bat
```

- 檢查連線狀態：

```powershell
.\Check_VPN.bat
```

## 其他
- 主要日誌為 `vpn_history.log`，位於專案根目錄。
- 若 OpenConnect 安裝在非預設路徑，請更新 `src\AutoVPN_Service.ps1` 中的 `OpenConnectExe` 變數（預設：`C:\Program Files\OpenConnect-GUI\openconnect.exe`）。
