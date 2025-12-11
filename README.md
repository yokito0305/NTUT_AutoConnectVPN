# AutoVPN 使用教學

本專案以 OpenConnect-GUI 取代 GlobalProtect，腳本已預設連線到 NTUT VPN Gateway，方便在 Windows 上快速連線。

## 快速安裝

執行根目錄的 `setup.bat` 會自動完成所有初始化工作：

```powershell
.\setup.bat
```

**安裝過程會自動：**
1. 下載並安裝 GitHub CLI（如未安裝）
2. 使用 GitHub CLI 下載 OpenConnect 執行檔到 `bin` 資料夾
3. 驗證所有必要的檔案都已正確載入
4. 建立 VPN 連接測試（可選）

安裝完成後即可開始使用。

## 手動安裝

如果你想自訂安裝過程，可以執行 `setup\Invoke-AutoVpnSetup.ps1`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "setup\Invoke-AutoVpnSetup.ps1"
```

## 初始設定（可選）

第一次使用建議執行 `Set_VPN_Credential.bat` 以儲存 VPN 帳號與密碼（產生的 `vpn_cred.xml` 僅能由同一使用者解密）。

也可以直接跳到「使用方式」執行 `Start_VPN.bat`，第一次登入時會自動執行初始化。

要建立或更新憑證（互動式）：

```powershell
.\Set_VPN_Credential.bat
```

## 使用方式

批次檔可直接雙擊執行。

- 啟動 VPN：`.\Start_VPN.bat`
- 停止 VPN：`.\Stop_VPN.bat`
- 檢查連線狀態：`.\Check_VPN.bat`

## 配置和進階設定

- 主要日誌為 `vpn_history.log`，位於專案根目錄
- OpenConnect 執行檔位於 `bin\openconnect.exe`（由安裝程序自動下載）
- VPN 設定（伺服器、協議等）集中在 `config\config.ps1`，詳見 `config\README.md`
- 更多詳細信息請參考 `test\TEST_SUITE.md` 瞭解系統設計

## 故障排除

如果設置過程中出現問題：

1. 確保已連接到網路（下載 OpenConnect 需要）
2. 檢查 `vpn_history.log` 瞭解詳細錯誤信息
3. 重新執行 `setup.bat` 以重試安裝
