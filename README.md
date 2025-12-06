# AutoVPN 使用教學

本專案以 OpenConnect-GUI 取代 GlobalProtect，腳本已預設連線到 NTUT VPN Gateway，方便在 Windows 上快速連線。

## 安裝
1. 下載並執行 OpenConnect-GUI 安裝程式：<https://www.infradead.org/openconnect-gui/download/openconnect-gui-1.6.2-win64.exe>
2. 安裝過程的「選擇元件」頁面，請勾選 **console**，其他維持預設即可。
3. 安裝完成頁面請取消勾選「執行 OpenConnect-GUI」後再按「完成」。

## 初始設定（可選）

第一次使用建議執行 `Set_VPN_Credential.bat` 以儲存 VPN 帳號與密碼（產生的 `vpn_cred.xml` 僅能由同一使用者解密）。

也可以直接跳到「使用方式」執行 `Start_VPN.bat`，第一次登入時會自動執行初始化。

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
