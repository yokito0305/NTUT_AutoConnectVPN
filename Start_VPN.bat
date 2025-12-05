@echo off
:: D:\Program Files\script\Start_VPN.bat

:: 切換到正確目錄
cd /d "%~dp0"

:: 為避免引號與空格問題，先將腳本完整路徑放到一個變數，
:: 再以 Start-Process 的多參數形式傳遞給提權的 PowerShell。
set "PSCRIPT=%~dp0src\AutoVPN_Service.ps1"

powershell -NoProfile -Command "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%PSCRIPT%\"' -Verb RunAs -WindowStyle Hidden"

exit