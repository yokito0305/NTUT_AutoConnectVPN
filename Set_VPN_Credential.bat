@echo off
:: Run the interactive credential setup in a visible PowerShell window
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Set_VPN_Credential.ps1"
exit
