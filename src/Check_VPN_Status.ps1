# File: D:\Program Files\script\src\Check_VPN_Status.ps1

function Show-VpnStatus {
    param(
        [string] $ProcessName = 'openconnect'
    )

    Clear-Host
    Write-Host "=== VPN Background Service Status Check ===" -ForegroundColor Cyan
    Write-Host "--------------------------------"

    $OC_Processes = @(Get-Process $ProcessName -ErrorAction SilentlyContinue)
    if ($OC_Processes.Count -gt 0) {
        Write-Host "[VPN Connection]" -NoNewline
        $PidList = ($OC_Processes | Select-Object -ExpandProperty Id) -join ' '
        Write-Host " * Connected (PID: $PidList)" -ForegroundColor Green

        # Use the first process for duration calculation
        $FirstProcess = $OC_Processes[0]
        if ($FirstProcess.StartTime) {
            $Duration = (Get-Date) - $FirstProcess.StartTime
            $TimeStr = "{0:hh}h {0:mm}m {0:ss}s" -f $Duration
            Write-Host "       Connection duration: $TimeStr"
        } else {
            Write-Host "       Connection duration: unknown"
        }
    } else {
        Write-Host "[VPN Connection]" -NoNewline
        Write-Host " o Disconnected" -ForegroundColor Red
    }

    Write-Host ""
}

if ($MyInvocation.InvocationName -ne '.') {
    Show-VpnStatus
}
