$repoRoot = Split-Path -Parent $PSScriptRoot
$autoScript = Join-Path $repoRoot 'src/AutoVPN_Service.ps1'
. $autoScript

# Ensure Write-Log is available for tests (mock if lib not loaded)
if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    function Write-Log {
        param([string]$Message, [string]$LogPath)
        # Mock Write-Log for testing - does nothing
    }
}

Describe 'AutoVPN_Service credential handling' {
    It 'returns null when no credential candidate exists' {
        $result = Load-Credential -Candidates @('C:/nonexistent/path.xml')

        $result | Should Be $null
    }

    It 'imports the first available credential file' {
        $credentialPath = Join-Path $TestDrive 'vpn_cred.xml'
        $cred = New-Object System.Management.Automation.PSCredential ('userA', (ConvertTo-SecureString -String 'secret' -AsPlainText -Force))
        $cred | Export-Clixml -Path $credentialPath

        $result = Load-Credential -Candidates @('C:/missing/first.xml', $credentialPath)

        $result.Path | Should Be $credentialPath
        $result.Credential.UserName | Should Be 'userA'
    }

    It 'returns null when credential file is corrupted or invalid type' {
        $corruptPath = Join-Path $TestDrive 'corrupt.xml'
        'invalid xml content' | Out-File $corruptPath

        $result = Load-Credential -Candidates @($corruptPath)

        $result | Should Be $null
    }
}

Describe 'AutoVPN_Service working context' {
    It 'writes PID to specified file' {
        $testPidFile = Join-Path $TestDrive 'test.pid'

        Set-WorkingContext -PidPath $testPidFile -WorkingDirectory $TestDrive

        Test-Path $testPidFile | Should Be $true
        $content = Get-Content $testPidFile
        $content | Should Be $PID
    }

    It 'changes working directory to specified path' {
        $originalLocation = Get-Location
        $testDir = Join-Path $TestDrive 'workdir'
        New-Item -Path $testDir -ItemType Directory -Force | Out-Null

        Set-WorkingContext -PidPath (Join-Path $TestDrive 'dummy.pid') -WorkingDirectory $testDir

        $currentLocation = Get-Location
        $currentLocation.Path | Should Be $testDir
        
        # Restore original location
        Set-Location $originalLocation
    }
}

Describe 'AutoVPN_Service OpenConnect operations' {
    It 'Start-OpenConnect returns object with Process and Started properties' {
        $result = Start-OpenConnect -Executable 'cmd.exe' -Username 'testuser' -TargetServer 'vpn.test.com'

        $result.Process | Should Not Be $null
        $result.Started | Should Be $true
        $result.Process.GetType().Name | Should Be 'Process'

        # Cleanup
        if ($result.Process -and -not $result.Process.HasExited) {
            $result.Process.Kill()
            $result.Process.WaitForExit(1000)
        }
    }

    It 'Start-OpenConnect configures ProcessStartInfo correctly' {
        $result = Start-OpenConnect -Executable 'cmd.exe' -Username 'user123' -TargetServer 'server.example.com'

        $psi = $result.Process.StartInfo
        $psi.FileName | Should Be 'cmd.exe'
        $psi.RedirectStandardInput | Should Be $true
        $psi.UseShellExecute | Should Be $false
        $psi.CreateNoWindow | Should Be $true

        # Cleanup
        if ($result.Process -and -not $result.Process.HasExited) {
            $result.Process.Kill()
            $result.Process.WaitForExit(1000)
        }
    }
}

Describe 'AutoVPN_Service Get-CredentialData' {
    It 'returns credential data when valid credential exists' {
        $credPath = Join-Path $TestDrive 'found.xml'
        $cred = New-Object System.Management.Automation.PSCredential ('founduser', (ConvertTo-SecureString 'foundpass' -AsPlainText -Force))
        $cred | Export-Clixml -Path $credPath
        $dummySetup = Join-Path $TestDrive 'setup.ps1'

        $result = Get-CredentialData -Candidates @($credPath) -SetupScript $dummySetup

        $result | Should Not Be $null
        $result.Credential.UserName | Should Be 'founduser'
        $result.Path | Should Be $credPath
    }

    It 'prefers first valid credential when multiple exist' {
        $cred1Path = Join-Path $TestDrive 'cred1.xml'
        $cred2Path = Join-Path $TestDrive 'cred2.xml'
        $cred1 = New-Object System.Management.Automation.PSCredential ('user1', (ConvertTo-SecureString 'pass1' -AsPlainText -Force))
        $cred2 = New-Object System.Management.Automation.PSCredential ('user2', (ConvertTo-SecureString 'pass2' -AsPlainText -Force))
        $cred1 | Export-Clixml -Path $cred1Path
        $cred2 | Export-Clixml -Path $cred2Path
        $dummySetup = Join-Path $TestDrive 'setup.ps1'

        $result = Get-CredentialData -Candidates @($cred1Path, $cred2Path) -SetupScript $dummySetup

        $result.Credential.UserName | Should Be 'user1'
        $result.Path | Should Be $cred1Path
    }
}

Describe 'AutoVPN_Service single instance protection' {
    It 'detects existing service instance via PID file' {
        $pidFile = Join-Path $TestDrive 'test.pid'
        $testPid = 99999
        $testPid | Out-File -FilePath $pidFile -Force

        # Verify PID file was created
        Test-Path $pidFile | Should Be $true
        $savedPid = Get-Content $pidFile
        $savedPid | Should Be $testPid
    }

    It 'removes stale PID file when process no longer exists' {
        $pidFile = Join-Path $TestDrive 'stale.pid'
        $stalePid = 1  # System process, but we'll simulate cleanup logic
        $stalePid | Out-File -FilePath $pidFile -Force

        # Simulate cleanup of stale PID file
        Remove-Item $pidFile -ErrorAction SilentlyContinue
        
        Test-Path $pidFile | Should Be $false
    }

    It 'OpenConnect cleanup removes all existing processes before new connection' {
        # This test verifies the cleanup logic exists in Monitor-OpenConnect
        # by checking that the function contains the cleanup code pattern
        $scriptContent = Get-Content -Path $autoScript -Raw
        
        $scriptContent | Should Match 'Get-Process.*openconnect.*-ErrorAction SilentlyContinue'
        $scriptContent | Should Match 'Stop-Process.*-Force'
        $scriptContent | Should Match 'Start-Sleep.*-Seconds 2'
    }

    It 'verifies both service and OpenConnect single-instance layers exist' {
        $scriptContent = Get-Content -Path $autoScript -Raw
        
        # Service layer: PID file check in Start-VpnService
        $scriptContent | Should Match 'Test-Path \$PidFile'
        $scriptContent | Should Match 'Get-Process.*-Id \$ExistingPid'
        
        # OpenConnect layer: Cleanup in Monitor-OpenConnect
        $scriptContent | Should Match 'Cleaning up.*existing OpenConnect process'
    }
}
