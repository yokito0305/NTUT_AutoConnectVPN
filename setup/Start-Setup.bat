@echo off
REM AutoVPN Setup Launcher
REM 自動化部署設置程序啟動器

setlocal enabledelayedexpansion

REM 確定腳本位置
set "SCRIPT_DIR=%~dp0"
set "SETUP_SCRIPT=%SCRIPT_DIR%Invoke-Setup.ps1"

REM 檢查腳本是否存在
if not exist "%SETUP_SCRIPT%" (
    echo Error: Setup script not found at %SETUP_SCRIPT%
    pause
    exit /b 1
)

REM 檢查 PowerShell 可用性
where powershell >nul 2>&1
if errorlevel 1 (
    echo Error: PowerShell not found in PATH
    pause
    exit /b 1
)

REM 顯示歡迎信息
echo.
echo ╔════════════════════════════════════════════════════════════╗
echo ║         AutoVPN 自動部署設置程序                            ║
echo ╚════════════════════════════════════════════════════════════╝
echo.

REM 執行 PowerShell 腳本
echo Launching setup script...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%SETUP_SCRIPT%" %*

REM 捕獲退出碼
set "EXIT_CODE=%errorlevel%"

echo.
if %EXIT_CODE% equ 0 (
    echo Setup completed successfully.
) else (
    echo Setup failed with error code: %EXIT_CODE%
)

echo.
pause
exit /b %EXIT_CODE%
