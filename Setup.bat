@echo off
REM AutoVPN Setup Launcher
REM This batch file launches the PowerShell setup script with proper permissions

setlocal enabledelayedexpansion

REM Determine the script directory
set SCRIPT_DIR=%~dp0setup
set SETUP_SCRIPT=%SCRIPT_DIR%\Invoke-Setup.ps1

REM Check if setup script exists
if not exist "%SETUP_SCRIPT%" (
    echo Error: Setup script not found at %SETUP_SCRIPT%
    echo Please ensure the setup directory and Invoke-Setup.ps1 exist.
    pause
    exit /b 1
)

REM Launch PowerShell setup script
echo Launching AutoVPN Setup...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%SETUP_SCRIPT%"

REM Capture the exit code
set EXIT_CODE=%ERRORLEVEL%

if %EXIT_CODE% equ 0 (
    echo.
    echo ===================================
    echo AutoVPN Setup completed successfully!
    echo ===================================
    echo.
    pause
) else (
    echo.
    echo ===================================
    echo Setup completed with errors (Exit code: %EXIT_CODE%)
    echo ===================================
    echo.
    pause
)

exit /b %EXIT_CODE%
