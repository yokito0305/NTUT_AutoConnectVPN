# AutoVPN 使用教學

本專案以 OpenConnect 取代 GlobalProtect，腳本已預設連線到 NTUT VPN Gateway，方便在 Windows 上快速連線。

## 快速開始

### 使用 Release 版本（推薦新手）

從 [GitHub Release](https://github.com/yokito0305/NTUT_AutoConnectVPN/releases) 下載最新的 `NTUT AutoVPN v1.0.0 - Beta` 壓縮檔。

**安裝步驟：**
1. 解壓縮到任意位置（例如 `C:\Program Files\AutoVPN`）
2. 雙擊執行 `Start_VPN.bat`
3. 第一次執行時會要求輸入 VPN 帳號與密碼

* OpenConnect 已經包含在其中，無需額外下載。

### 使用 Git Clone 版本（開發者）

從 GitHub Repository clone 下來的開發版本需要額外設置：

```bash
git clone https://github.com/yokito0305/NTUT_AutoConnectVPN.git
cd NTUT_AutoConnectVPN
.\setup.bat
```

**setup.bat 會自動：**
1. 下載最新的 OpenConnect 編譯版本到 `bin` 資料夾
2. 驗證配置檔案
3. 執行初始化檢查

設置完成後執行 `Start_VPN.bat`。

## 初始設定

第一次執行時，系統會自動要求輸入 VPN 帳號與密碼：
- 帳號與密碼會以加密方式存儲在 `vpn_cred.xml`（僅該使用者可解密）
- 存儲後後續執行會直接使用已存儲的憑證

如需變更憑證，執行 `Set_VPN_Credential.bat`：

```powershell
.\Set_VPN_Credential.bat
```

## 使用方式

所有批次檔都可直接雙擊執行，或在 PowerShell 中執行。

### 基本操作

| 批次檔 | 功能 | 說明 |
|--------|------|------|
| `Start_VPN.bat` | 啟動 VPN | 在背景執行，自動重連 |
| `Stop_VPN.bat` | 停止 VPN | 終止所有連線 |
| `Check_VPN.bat` | 檢查狀態 | 顯示目前連線狀態 |
| `Set_VPN_Credential.bat` | 設置認證 | 變更 VPN 帳號密碼 |

### 命令列執行範例

```powershell
# 啟動 VPN
.\Start_VPN.bat

# 停止 VPN
.\Stop_VPN.bat

# 查看連線狀態（新視窗）
.\Check_VPN.bat
```

## 配置和進階設定

### 組態檔案

- **VPN 設定**：`config\config.ps1` - 包含伺服器位址、協議等設定
- **日誌檔案**：`vpn_history.log` - VPN 連線紀錄
- **認證檔案**：`vpn_cred.xml` - 加密存儲的 VPN 帳號密碼
- **OpenConnect 執行檔**：`bin\openconnect.exe` - VPN 客戶端

詳細說明見 `config\README.md` 和 `config\QUICKREF.md`。

### 開發者設定

若從 Git Clone 版本開發，可執行：

```powershell
# 下載最新的 OpenConnect 編譯版本
.\setup\Invoke-Setup.ps1

# 僅驗證配置（不下載）
.\setup\Invoke-Setup.ps1 -SkipOpenConnect

# 執行單元測試
cd .\test
Invoke-Pester
```

詳見 `setup\README.md`。

### 版本間的差異

| 功能 | Release 版本 | Git Clone 版本 |
|------|-------------|----------------|
| OpenConnect | ✅ 包含 | ❌ 需下載 |
| 解壓即用 | ✅ 是 | ❌ 需 setup |
| 開發工具 | ❌ 無 | ✅ 包含測試套件 |

## 故障排除

### Release 版本

**問題**：執行 `Start_VPN.bat` 後未看到任何反應

**解決**：
1. 檢查 PowerShell 執行原則是否允許執行腳本
2. 查看 `vpn_history.log` 檔案瞭解錯誤詳情
3. 確保 `bin\openconnect.exe` 存在

### Git Clone 版本

**問題**：執行 `setup.bat` 失敗

**解決**：
1. 確保已連接到網路（需下載 OpenConnect）
2. 檢查 GitHub API 是否可訪問
3. 手動下載 Release 並提取到 `bin\` 目錄

### 常見問題

**VPN 連線後立即斷開**
- 檢查帳號密碼是否正確
- 查看 `vpn_history.log` 的錯誤信息

**無法儲存認證檔案**
- 確保 `vpn_cred.xml` 有寫入權限
- 檢查磁碟空間是否充足

**連線中斷**
- NTUT VPN 伺服器可能每 4 小時強制斷開，系統會自動重連
- 若持續失敗，嘗試手動執行 `Set_VPN_Credential.bat` 重新驗證認證

## 相關資源

### 文檔

- [設置指南](setup/README.md) - 詳細的安裝和配置說明
- [配置參考](config/README.md) - VPN 設定詳解
- [快速配置](config/QUICKREF.md) - 常用設定修改
- [測試文檔](test/TEST_SUITE.md) - 單元測試說明

### 官方連結

- [OpenConnect 官網](https://www.infradead.org/openconnect) - VPN 客戶端資訊
- [NTUT VPN](https://vpn.ntut.edu.tw) - 學校 VPN 入口
- [GitHub Repository](https://github.com/yokito0305/NTUT_AutoConnectVPN) - 源代碼

## 許可證

本專案採用 MIT 許可證。詳見 LICENSE 檔案。

## 反饋和支援

如遇到問題或有建議，歡迎在 [GitHub Issues](https://github.com/yokito0305/NTUT_AutoConnectVPN/issues) 提出。
