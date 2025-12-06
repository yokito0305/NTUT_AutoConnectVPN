@echo off
:: D:\Program Files\script\Start_VPN.bat
:: 切換到正確目錄
cd /d "%~dp0"

:: 路徑設定
set "ROOT=%~dp0"
set "PS_SERVICE=%ROOT%src\AutoVPN_Service.ps1"
set "PS_SETUP=%ROOT%src\Set_VPN_Credential.ps1"
set "CRED_ROOT=%ROOT%vpn_cred.xml"
set "CRED_SRC=%ROOT%src\vpn_cred.xml"

:: 如果憑證不存在，先開啟互動式設定腳本（可見視窗，等待完成）
set "CRED_FOUND="
for %%F in ("%CRED_ROOT%" "%CRED_SRC%") do if exist %%~fF set "CRED_FOUND=1"
if not defined CRED_FOUND (
    powershell -NoProfile -Command "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%PS_SETUP%\"' -Verb RunAs -Wait -WindowStyle Normal"
)

:: 再次確認憑證存在才啟動隱藏的服務腳本
set "CRED_CONFIRMED="
for %%F in ("%CRED_ROOT%" "%CRED_SRC%") do if exist %%~fF set "CRED_CONFIRMED=1"
if defined CRED_CONFIRMED (
    powershell -NoProfile -Command "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%PS_SERVICE%\"' -Verb RunAs -WindowStyle Hidden"
) else (
    echo 找不到 vpn_cred.xml，服務不會啟動。
)

exit /b
