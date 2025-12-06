@echo off
:: 檔案名稱: D:\Program Files\script\雙擊查看狀態.bat

cd /d "%~dp0"

:: Execute PowerShell script directly in current console window (no new window)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Check_VPN_Status.ps1"
pause