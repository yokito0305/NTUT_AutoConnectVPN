@echo off
:: 檔案名稱: D:\Program Files\script\雙擊查看狀態.bat

cd /d "%~dp0"

:: 不需要管理員權限通常也能查看；在新視窗啟動 PowerShell 執行 src 內的檢查腳本
:: 使用 start 直接開新視窗並以 -File 傳入完整路徑（較可靠且可正確處理含空白路徑）
start "Check VPN" powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0src\Check_VPN_Status.ps1"

exit