@echo off
:: D:\Program Files\script\Start_VPN.bat
:: 切換到正確目錄
cd /d "%~dp0"

:: 路徑設定
set "ROOT=%~dp0"
set "PS_SERVICE=%ROOT%src\AutoVPN_Service.ps1"

:: 以單一提權呼叫服務腳本；腳本本身會在需要時開啟互動式設定並且顯示視窗
powershell -NoProfile -Command "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%PS_SERVICE%\"' -Verb RunAs -WindowStyle Hidden"

exit /b
