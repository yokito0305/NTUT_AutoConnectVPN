# AutoVPN 使用教學

本專案提供用於控制 OpenConnect-GUI（OpenConnect GUI）VPN 的簡單批次與 PowerShell 腳本，包含儲存憑證、啟動/停止 VPN，以及檢查連線狀態。

**安裝與使用重點**

1. 需要先從 OpenConnect GUI 下載並安裝：

   - 下載連結：

     https://www.infradead.org/openconnect-gui/download/openconnect-gui-1.6.2-win64.exe

2. 安裝完成時請務必取消勾選「執行 OpenConnect-GUI」再按「完成」。

3. 第一次使用前請先執行 `Set_VPN_Credential.bat`，以儲存 VPN 的帳號與密碼：

   - 執行方式（PowerShell 或命令提示字元中，請切換到專案資料夾）：

```powershell
.\Set_VPN_Credential.bat
```

   - 憑證會被匯出為 `vpn_cred.xml`（以 `Export-Clixml` 儲存，僅能由同一 Windows 使用者解密）。

4. 啟動 / 停止 VPN：

   - 啟動：

```powershell
.\Start_VPN.bat
```

   - 停止：

```powershell
.\Stop_VPN.bat
```

5. 檢查 VPN 狀態：

   - 使用專案根目錄的 `Check_VPN.bat`（或 `Check_VPN_Status.ps1`）：

```powershell
.\Check_VPN.bat
```

6. 日誌（logs）資訊：

   - 主要日誌檔案為 `vpn_history.log`，位於專案根目錄（`AutoVPN` 資料夾內）。

7. 其他備註與除錯建議：

   - 腳本預設會使用下列執行檔路徑，若您將 OpenConnect 安裝到其他位置，請更新 `src\AutoVPN_Service.ps1` 中的 `OpenConnectExe` 變數：

```
C:\Program Files\OpenConnect-GUI\openconnect.exe
```

   - 若出現「找不到憑證」或驗證失敗的訊息，請重新執行 `Set_VPN_Credential.bat` 並確認以相同使用者帳號執行服務/腳本。

   - 日誌會記錄連線嘗試、啟動/停止事件與錯誤訊息，遇到問題時請把 `vpn_history.log` 的相關區段提供給系統管理員以利診斷。

歡迎告訴我是否要我幫你把 README 的內容再擴充成英文版本、增加截圖、或在批次檔內加入安裝路徑自動檢查的功能。
