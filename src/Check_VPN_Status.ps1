# File: D:\Program Files\script\src\Check_VPN_Status.ps1

Clear-Host
Write-Host "=== VPN Background Service Status Check ===" -ForegroundColor Cyan
Write-Host "--------------------------------"

# Only show VPN connection status and connection duration (or disconnected)
$OC_Process = Get-Process openconnect -ErrorAction SilentlyContinue
if ($OC_Process) {
    Write-Host "[VPN Connection]" -NoNewline
    Write-Host " * Connected (PID: $($OC_Process.Id))" -ForegroundColor Green

    $Duration = (Get-Date) - $OC_Process.StartTime
    $TimeStr = "{0:hh}h {0:mm}m {0:ss}s" -f $Duration
    Write-Host "       Connection duration: $TimeStr"
} else {
    Write-Host "[VPN Connection]" -NoNewline
    Write-Host " o Disconnected" -ForegroundColor Red
}
Write-Host ""
