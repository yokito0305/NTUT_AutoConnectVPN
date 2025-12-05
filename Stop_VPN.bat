@echo off
:: D:\Program Files\script\Stop_VPN.bat

:: 切換到正確目錄
cd /d "%~dp0"

:: 將完整腳本路徑放入變數以避免空格/引號問題
set "PSCRIPT=%~dp0src\Stop_VPN_Logic.ps1"

:: 以多參數 ArgumentList 傳遞給提權的 PowerShell
powershell -NoProfile -Command "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%PSCRIPT%\"' -Verb RunAs -WindowStyle Hidden"

exit