$repoRoot = Split-Path -Parent $PSScriptRoot
$autoScript = Join-Path $repoRoot 'src/AutoVPN_Service.ps1'
. $autoScript

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
}

Describe 'AutoVPN_Service working context' {
    It 'writes PID to specified file' {
        $testPidFile = Join-Path $TestDrive 'test.pid'
        $originalLocation = Get-Location

        try {
            Set-WorkingContext -PidPath $testPidFile -WorkingDirectory $TestDrive

            Test-Path $testPidFile | Should Be $true
            (Get-Content $testPidFile) | Should Be $PID
        } finally {
            Set-Location $originalLocation
        }
    }
}

Describe 'AutoVPN_Service runtime state consistency' {
    It 'backfills top-level assigned ip and gateway from network config plan when missing' {
        $testStateFile = Join-Path $TestDrive 'vpn_state.json'
        $testStopRequest = Join-Path $TestDrive 'vpn.stop.request'
        $originalStateFile = $script:StateFile
        $originalStopRequestFile = $script:StopRequestFile

        try {
            $script:StateFile = $testStateFile
            $script:StopRequestFile = $testStopRequest

            $plan = [pscustomobject]@{
                AssignedIp = '172.24.232.41'
                Gateway = '140.124.4.100'
            }

            Update-ServiceRuntimeState -ServiceState 'running' -SessionState 'connected' -Reason 'VPN tunnel established' -OpenConnectPid 222 -ConnectedAt (Get-Date) -NetworkConfigPlan $plan

            $state = Read-VpnRuntimeState -StatePath $testStateFile
            $state.assigned_ip | Should Be '172.24.232.41'
            $state.gateway | Should Be '140.124.4.100'
        } finally {
            $script:StateFile = $originalStateFile
            $script:StopRequestFile = $originalStopRequestFile
        }
    }

    It 'parses timestamp-prefixed configured, gateway, and expiry events' {
        Mock -CommandName Update-RunningSessionRuntimeState -MockWith { }
        Mock -CommandName Update-NetworkConfigurationPreviewState -MockWith { }

        $state = [hashtable]::Synchronized(@{
            SessionState = 'connected'
            NetworkConfigEvidence = New-NetworkConfigurationEvidence
        })

        Update-OpenConnectSessionStateFromLine -State $state -Line '[2026-04-06 16:14:13] Configured as 172.24.232.2, with SSL disconnected and ESP established' -Component 'openconnect' -LogPath (Join-Path $TestDrive 'vpn_history.log')
        Update-OpenConnectSessionStateFromLine -State $state -Line '[2026-04-06 16:14:13] Public VPN Gateway Address: 140.124.4.100' -Component 'openconnect' -LogPath (Join-Path $TestDrive 'vpn_history.log')
        Update-OpenConnectSessionStateFromLine -State $state -Line '[2026-04-06 16:14:13] Session authentication will expire at Mon Apr 06 20:14:13 2026' -Component 'openconnect' -LogPath (Join-Path $TestDrive 'vpn_history.log')

        $state.AssignedIp | Should Be '172.24.232.2'
        $state.Gateway | Should Be '140.124.4.100'
        $state.SessionExpiresAt | Should Not Be $null
    }

    It 'keeps connected reason as warning summary when script warning appears after connect' {
        Mock -CommandName Update-RunningSessionRuntimeState -MockWith { }
        Mock -CommandName Update-NetworkConfigurationPreviewState -MockWith { }

        $state = [hashtable]::Synchronized(@{
            SessionState = 'connected'
            ConnectedAt = Get-Date
            NetworkConfigEvidence = New-NetworkConfigurationEvidence
        })

        Update-OpenConnectSessionStateFromLine -State $state -Line '[2026-04-06 17:07:43] Script did not complete within 10 seconds.' -Component 'openconnect' -LogPath (Join-Path $TestDrive 'vpn_history.log')

        $state.ScriptWarningDetected | Should Be $true
        Assert-MockCalled -CommandName Update-RunningSessionRuntimeState -Times 1 -Exactly -ParameterFilter {
            $Reason -eq 'VPN connected, but network configuration script reported warnings. Check vpn_openconnect_raw.log for details.'
        }
    }
}

Describe 'AutoVPN_Service argument building' {
    It 'builds default GlobalProtect arguments with diagnostics and non-interactive mode' {
        $args = Get-OpenConnectArguments -Username 'testuser' -TargetServer 'vpn.test.com'
        $joinedArgs = $args -join ' '

        $joinedArgs | Should Match '--protocol=gp'
        $joinedArgs | Should Match '--user=testuser'
        $joinedArgs | Should Match '--passwd-on-stdin'
        $joinedArgs | Should Match '--non-inter'
        $joinedArgs | Should Match '(^| )-v( |$)'
        $joinedArgs | Should Match '--timestamp'
        $joinedArgs | Should Not Match '--no-dtls'
        $joinedArgs | Should Not Match '--reconnect-timeout=30'
    }

    It 'supports elevated diagnostic verbosity for HTTP body capture runs' {
        $args = Get-OpenConnectArguments -Username 'testuser' -TargetServer 'vpn.test.com' -VerboseLevel 3
        $joinedArgs = $args -join ' '

        $joinedArgs | Should Match '(^| )-vvv( |$)'
    }

    It 'adds optional reconnect-timeout and HTTPS-only fallback flags when configured' {
        $args = Get-OpenConnectArguments -Username 'testuser' -TargetServer 'vpn.test.com' -ReconnectTimeoutSeconds 30 -NoDtls $true -DumpHttpTraffic $true -ScriptCommand 'C:\vpn\vpnc-script-win.js'
        $joinedArgs = $args -join ' '

        $joinedArgs | Should Match '--reconnect-timeout=30'
        $joinedArgs | Should Match '--no-dtls'
        $joinedArgs | Should Match '--dump-http-traffic'
        $joinedArgs | Should Match '--script=C:\\vpn\\vpnc-script-win\.js'
        $joinedArgs | Should Not Match 'cscript\.exe'
    }

    It 'formats command line arguments without introducing plaintext secrets' {
        $args = Get-OpenConnectArguments -Username 'testuser' -TargetServer 'vpn.test.com'
        $commandLine = ConvertTo-CommandLineString -Arguments $args

        $commandLine | Should Match '--user=testuser'
        $commandLine | Should Not Match 'super-secret-password'
    }

    It 'builds script diagnostics environment variables from config flags' {
        $script:Config_OpenConnectScriptDryRun = $true
        $script:Config_OpenConnectScriptSkipDns = $true
        $script:Config_OpenConnectScriptSkipRoutes = $false
        $script:Config_OpenConnectScriptSkipIpv6 = $true

        $envVars = Get-OpenConnectScriptEnvironment -RootDir $repoRoot

        $envVars['VPNC_SCRIPT_DRY_RUN'] | Should Be '1'
        $envVars['VPNC_SCRIPT_SKIP_DNS'] | Should Be '1'
        $envVars.ContainsKey('VPNC_SCRIPT_SKIP_ROUTES') | Should Be $false
        $envVars['VPNC_SCRIPT_SKIP_IPV6'] | Should Be '1'
    }

    It 'resolves the primary script path from a relative config value' {
        $script:Config_OpenConnectUseMinimalScript = $false
        $script:Config_OpenConnectScriptCommand = 'bin\vpnc-script-win.js'

        $scriptPath = Get-VpnConfig -ConfigKey 'OpenConnectScriptCommand' -RootDir $repoRoot

        $scriptPath | Should Be (Join-Path $repoRoot 'bin\vpnc-script-win.js')
    }

    It 'can switch the resolved script path to the minimal diagnostic script' {
        $script:Config_OpenConnectUseMinimalScript = $true
        $script:Config_OpenConnectScriptCommand = 'bin\vpnc-script-win.js'
        $script:Config_OpenConnectMinimalScriptCommand = 'bin\vpnc-script-win.minimal.js'

        $scriptPath = Get-VpnConfig -ConfigKey 'OpenConnectScriptCommand' -RootDir $repoRoot
        $minimalPath = Get-VpnConfig -ConfigKey 'OpenConnectMinimalScriptCommand' -RootDir $repoRoot

        $scriptPath | Should Be $minimalPath
        $scriptPath | Should Match 'vpnc-script-win\.minimal\.js$'
    }

    It 'resolves the HTTP body dump path from a relative config value' {
        $bodyDumpPath = Get-VpnConfig -ConfigKey 'OpenConnectHttpBodyDumpFile' -RootDir $repoRoot

        $bodyDumpPath | Should Be (Join-Path $repoRoot 'vpn_openconnect_http_body_dump.log')
    }

    It 'passes dump-http-traffic through supervised session argument construction' {
        $capturedArguments = $null
        $capturedInputLines = $null

        Mock -CommandName Stop-ExistingOpenConnectProcesses -MockWith { }
        Mock -CommandName Get-OpenConnectScriptEnvironment -MockWith { $null }
        Mock -CommandName Invoke-SupervisedProcess -MockWith {
            param(
                [string] $Executable,
                [string[]] $Arguments,
                [string[]] $InputLines
            )

            $script:capturedArguments = @($Arguments)
            $script:capturedInputLines = @($InputLines)
            return [pscustomobject]@{
                Classification = 'unknown_failure'
                ShouldRetry = $false
                ExitCode = 1
                ProcessId = 1234
                DurationSeconds = 0.1
                SessionState = 'disconnected'
                TransportMode = $null
                LastTransportEvent = $null
                AssignedIp = $null
                SessionExpiresAt = $null
                Gateway = $null
                LastStdOut = $null
                LastStdErr = $null
                LastActivity = $null
                AuthFailureDetected = $false
                NetworkFailureDetected = $false
                ScriptWarningDetected = $false
                ScriptWarningReason = $null
            }
        }

        $null = Invoke-OpenConnectSession -Executable 'openconnect.exe' -Username 'user' -Password 'secret' -TargetServer 'vpn.test.com' -StatusScript (Join-Path $TestDrive 'status.ps1') -PidPath (Join-Path $TestDrive 'vpn.pid') -DumpHttpTraffic $true

        ($script:capturedArguments -join ' ') | Should Match '--dump-http-traffic'
        $script:capturedInputLines.Count | Should Be 1
        $script:capturedInputLines[0] | Should Be 'secret'
    }

    It 'repeats the OpenConnect password on stdin when configured' {
        $stdinLines = Get-OpenConnectStandardInputLines -Password 'secret' -RepeatCount 3

        $stdinLines.Count | Should Be 3
        $stdinLines | Should Be @('secret', 'secret', 'secret')
    }

    It 'passes repeated stdin lines to OpenConnect when requested' {
        $capturedInputLines = $null

        Mock -CommandName Stop-ExistingOpenConnectProcesses -MockWith { }
        Mock -CommandName Get-OpenConnectScriptEnvironment -MockWith { $null }
        Mock -CommandName Invoke-SupervisedProcess -MockWith {
            param(
                [string] $Executable,
                [string[]] $Arguments,
                [string[]] $InputLines
            )

            $script:capturedInputLines = @($InputLines)
            return [pscustomobject]@{
                Classification = 'unknown_failure'
                ShouldRetry = $false
                ExitCode = 1
                ProcessId = 1234
                DurationSeconds = 0.1
                SessionState = 'disconnected'
                TransportMode = $null
                LastTransportEvent = $null
                AssignedIp = $null
                SessionExpiresAt = $null
                Gateway = $null
                LastStdOut = $null
                LastStdErr = $null
                LastActivity = $null
                AuthFailureDetected = $false
                NetworkFailureDetected = $false
                ScriptWarningDetected = $false
                ScriptWarningReason = $null
            }
        }

        $null = Invoke-OpenConnectSession -Executable 'openconnect.exe' -Username 'user' -Password 'secret' -TargetServer 'vpn.test.com' -StatusScript (Join-Path $TestDrive 'status.ps1') -PidPath (Join-Path $TestDrive 'vpn.pid') -PasswordStdinRepeatCount 3

        $script:capturedInputLines | Should Be @('secret', 'secret', 'secret')
    }
}

Describe 'AutoVPN_Service network configuration seams' {
    It 'rejects non-contiguous IPv4 netmasks when converting to prefix length' {
        (ConvertTo-Ipv4PrefixLength -Netmask '255.0.255.0') | Should Be $null
    }

    It 'rejects out-of-range IPv4 netmask octets when converting to prefix length' {
        (ConvertTo-Ipv4PrefixLength -Netmask '255.255.999.0') | Should Be $null
    }

    It 'builds a server-derived network configuration plan with normalized collections' {
        $route = New-NetworkConfigurationRoute -Destination '140.124.0.0' -PrefixLength 16 -RouteType 'include'
        $plan = New-NetworkConfigurationPlan -AssignedIp '10.10.10.5' -PrefixLength 24 -Gateway '140.124.4.100' -DnsServers @('8.8.8.8') -DnsTargetAdapter '區域連線' -DnsTargetInterfaceIndex 18 -DnsOwnedServers @('8.8.8.8') -RouteTargetInterfaceIndex 18 -RouteOwnedEntries @($route) -SplitIncludeRoutes @($route)

        $plan.Source | Should Be 'server_derived'
        $plan.AssignedIp | Should Be '10.10.10.5'
        $plan.PrefixLength | Should Be 24
        $plan.DnsServers.Count | Should Be 1
        $plan.DnsTargetInterfaceIndex | Should Be 18
        $plan.DnsOwnedServers.Count | Should Be 1
        $plan.RouteTargetInterfaceIndex | Should Be 18
        $plan.RouteOwnedEntries.Count | Should Be 1
        $plan.SplitIncludeRoutes.Count | Should Be 1
    }

    It 'normalizes PSCustomObject metadata when rebuilding a network configuration plan' {
        $metadata = [pscustomobject]@{
            replay_source = 'replay'
            portal = 'NTUTSSLVPN'
            timeout = 3600
        }

        $plan = New-NetworkConfigurationPlan -AssignedIp '172.24.232.47' -PrefixLength 32 -Gateway '140.124.4.100' -Metadata $metadata

        $plan.Metadata.GetType().Name | Should Be 'Hashtable'
        $plan.Metadata['replay_source'] | Should Be 'replay'
        $plan.Metadata['portal'] | Should Be 'NTUTSSLVPN'
        $plan.Metadata['timeout'] | Should Be 3600
    }

    It 'creates a preview-only network configuration context without applying changes' {
        $context = New-NetworkConfigurationContext -RootDir $repoRoot -LogPath (Join-Path $TestDrive 'vpn_history.log') -StatePath (Join-Path $TestDrive 'vpn_state.json')
        $plan = New-NetworkConfigurationPlan
        $result = Invoke-NetworkConfigurationPreview -Plan $plan -Context $context

        $context.RootDir | Should Be $repoRoot
        $result.Status | Should Be 'not_ready'
        [string]::IsNullOrEmpty($result.Error) | Should Be $true
    }

    It 'parses server-derived DNS and split-route evidence into a normalized plan' {
        $evidence = New-NetworkConfigurationEvidence

        Update-NetworkConfigurationEvidenceFromLine -Evidence $evidence -Line 'Configured as 172.24.232.72, netmask 255.255.255.255' | Should Be $true
        Update-NetworkConfigurationEvidenceFromLine -Evidence $evidence -Line 'Public VPN Gateway Address: 140.124.4.100' | Should Be $true
        Update-NetworkConfigurationEvidenceFromLine -Evidence $evidence -Line 'Received DNS server 8.8.8.8' | Should Be $true
        Update-NetworkConfigurationEvidenceFromLine -Evidence $evidence -Line 'Received split include route 140.124.0.0/255.255.0.0' | Should Be $true

        $plan = Convert-OpenConnectEvidenceToNetworkConfigurationPlan -Evidence $evidence

        $plan.AssignedIp | Should Be '172.24.232.72'
        $plan.PrefixLength | Should Be 32
        $plan.Gateway | Should Be '140.124.4.100'
        $plan.DnsServers[0] | Should Be '8.8.8.8'
        $plan.SplitIncludeRoutes[0].Destination | Should Be '140.124.0.0'
        $plan.SplitIncludeRoutes[0].PrefixLength | Should Be 16
    }

    It 'parses timestamped real-session evidence for assigned ip gateway and interface hints' {
        $evidence = New-NetworkConfigurationEvidence

        Update-NetworkConfigurationEvidenceFromLine -Evidence $evidence -Line '[2026-04-03 16:48:28] Connected to HTTPS on vpn.ntut.edu.tw with ciphersuite (TLS1.2)' | Should Be $true
        Update-NetworkConfigurationEvidenceFromLine -Evidence $evidence -Line '[2026-04-03 16:48:28] Configured as 172.24.232.43, with SSL disconnected and ESP established' | Should Be $true
        Update-NetworkConfigurationEvidenceFromLine -Evidence $evidence -Line '[2026-04-03 16:48:28] Unknown GlobalProtect config tag <include-split-tunneling-domain>: ' | Should Be $true
        Update-NetworkConfigurationEvidenceFromLine -Evidence $evidence -Line "`t`t`t*.ieee.org" | Should Be $true
        Update-NetworkConfigurationEvidenceFromLine -Evidence $evidence -Line "[2026-04-03 16:48:28] Using TAP-Windows device 'Local Area Connection', index 18" | Should Be $true

        $plan = Convert-OpenConnectEvidenceToNetworkConfigurationPlan -Evidence $evidence

        $plan.AssignedIp | Should Be '172.24.232.43'
        $plan.Gateway | Should Be 'vpn.ntut.edu.tw'
        $plan.SplitIncludeDomains[0] | Should Be '*.ieee.org'
        $plan.InterfaceHints[0] | Should Match 'index 18'
    }

    It 'parses gateway getconfig XML body dump into server-derived DNS and split-route plan fields' {
        $bodyDumpPath = Join-Path $TestDrive 'vpn_openconnect_http_body_dump.log'
        @(
            '=== BEGIN HTTP XML BODY /ssl-vpn/getconfig.esp [ssl_vpn_getconfig] (2026-04-04 18:00:00) ===',
            '<?xml version="1.0" encoding="UTF-8" ?>',
            '<response status="success">',
            '  <gw-address>140.124.4.100</gw-address>',
            '  <ip-address>172.24.232.111</ip-address>',
            '  <netmask>255.255.255.255</netmask>',
            '  <dns><member>140.124.13.1</member><member>140.124.13.2</member></dns>',
            '  <default-gateway>172.24.232.111</default-gateway>',
            '  <access-routes><member>140.124.0.0/16</member><member>140.124.13.1/32</member></access-routes>',
            '  <exclude-access-routes><member>10.0.0.0/8</member></exclude-access-routes>',
            '  <include-split-tunneling-domain><member>*.ieee.org</member></include-split-tunneling-domain>',
            '  <portal>NTUTSSLVPN</portal>',
            '  <lifetime>14400</lifetime>',
            '  <timeout>3600</timeout>',
            '  <disconnect-on-idle>3600</disconnect-on-idle>',
            '  <need-tunnel>yes</need-tunnel>',
            '  <ipsec><udp-port>4501</udp-port><ipsec-mode>esp-tunnel</ipsec-mode></ipsec>',
            '</response>',
            '=== END HTTP XML BODY /ssl-vpn/getconfig.esp ==='
        ) | Set-Content -Path $bodyDumpPath

        $evidence = New-NetworkConfigurationEvidence
        $plan = Convert-OpenConnectEvidenceToNetworkConfigurationPlan -Evidence $evidence -AdditionalMetadata @{
            http_config_body_path = $bodyDumpPath
        }

        $plan.AssignedIp | Should Be '172.24.232.111'
        $plan.PrefixLength | Should Be 32
        $plan.Gateway | Should Be '140.124.4.100'
        $plan.DnsServers | Should Be @('140.124.13.1', '140.124.13.2')
        $plan.SplitIncludeRoutes.Count | Should Be 2
        $plan.SplitIncludeRoutes[0].DestinationPrefix | Should Be '140.124.0.0/16'
        $plan.SplitExcludeRoutes.Count | Should Be 1
        $plan.SplitExcludeRoutes[0].DestinationPrefix | Should Be '10.0.0.0/8'
        $plan.SplitIncludeDomains | Should Be @('*.ieee.org')
        $plan.Metadata.xml_primary_document | Should Be 'ssl_vpn_getconfig'
        $plan.Metadata.default_gateway | Should Be '172.24.232.111'
        $plan.Metadata.ipsec_udp_port | Should Be '4501'
        $plan.Metadata.http_config_body_path | Should Be $bodyDumpPath
    }

    It 'prefers gateway getconfig XML values over partial line-based evidence' {
        $bodyDumpPath = Join-Path $TestDrive 'vpn_openconnect_http_body_dump.log'
        @(
            '=== BEGIN HTTP XML BODY /ssl-vpn/getconfig.esp [ssl_vpn_getconfig] (2026-04-04 18:00:00) ===',
            '<?xml version="1.0" encoding="UTF-8" ?>',
            '<response status="success">',
            '  <gw-address>140.124.4.100</gw-address>',
            '  <ip-address>172.24.232.111</ip-address>',
            '  <netmask>255.255.255.255</netmask>',
            '  <dns><member>140.124.13.1</member><member>140.124.13.2</member></dns>',
            '  <access-routes><member>140.124.0.0/16</member></access-routes>',
            '</response>',
            '=== END HTTP XML BODY /ssl-vpn/getconfig.esp ==='
        ) | Set-Content -Path $bodyDumpPath

        $evidence = New-NetworkConfigurationEvidence
        Update-NetworkConfigurationEvidenceFromLine -Evidence $evidence -Line 'Connected to HTTPS on vpn.ntut.edu.tw with ciphersuite (TLS1.2)' | Should Be $true
        Update-NetworkConfigurationEvidenceFromLine -Evidence $evidence -Line 'Configured as 172.24.232.43, with SSL disconnected and ESP established' | Should Be $true

        $plan = Convert-OpenConnectEvidenceToNetworkConfigurationPlan -Evidence $evidence -AdditionalMetadata @{
            http_config_body_path = $bodyDumpPath
        }

        $plan.AssignedIp | Should Be '172.24.232.111'
        $plan.Gateway | Should Be '140.124.4.100'
        $plan.DnsServers | Should Be @('140.124.13.1', '140.124.13.2')
        $plan.SplitIncludeRoutes.Count | Should Be 1
    }

    It 'builds a replay-derived plan from a real replay directory layout' {
        $replayDir = Join-Path $TestDrive 'http-replay\20260404-180000'
        New-Item -ItemType Directory -Path $replayDir -Force | Out-Null

        @(
            '<?xml version="1.0" encoding="UTF-8" ?>',
            '<prelogin-response><server-ip>140.124.4.100</server-ip></prelogin-response>'
        ) | Set-Content -Path (Join-Path $replayDir '01-portal-prelogin.body.xml')

        @(
            '<?xml version="1.0" encoding="UTF-8" ?>',
            '<response status="success">',
            '  <gw-address>140.124.4.100</gw-address>',
            '  <ip-address>172.24.232.111</ip-address>',
            '  <netmask>255.255.255.255</netmask>',
            '  <dns><member>140.124.13.1</member><member>140.124.13.2</member></dns>',
            '  <access-routes><member>140.124.0.0/16</member></access-routes>',
            '  <include-split-tunneling-domain><member>*.ieee.org</member></include-split-tunneling-domain>',
            '</response>'
        ) | Set-Content -Path (Join-Path $replayDir '04-gateway-getconfig.body.xml')

        $plan = Get-NetworkConfigurationPlanFromReplayDirectory -ReplayDirectory $replayDir -Server 'vpn.ntut.edu.tw' -UserName '113598087'

        $plan.Source | Should Be 'server_derived'
        $plan.AssignedIp | Should Be '172.24.232.111'
        $plan.Gateway | Should Be '140.124.4.100'
        $plan.DnsServers | Should Be @('140.124.13.1', '140.124.13.2')
        $plan.SplitIncludeRoutes.Count | Should Be 1
        $plan.Metadata.replay_source | Should Be 'replay'
    }

    It 'uses a fresh replay cache entry without spawning a replay process' {
        $cachePath = Join-Path $TestDrive 'vpn_config_cache.json'
        $cachedPlan = New-NetworkConfigurationPlan -AssignedIp '172.24.232.111' -PrefixLength 32 -Gateway '140.124.4.100' -DnsServers @('140.124.13.1', '140.124.13.2') -SplitIncludeRoutes @((New-NetworkConfigurationRoute -Destination '140.124.0.0' -PrefixLength 16 -RouteType 'include'))
        Save-ReplayConfigurationCacheEntries -CachePath $cachePath -Entries @(
            [pscustomobject]@{
                username = '113598087'
                server = 'vpn.ntut.edu.tw'
                gateway = '140.124.4.100'
                captured_at = (Get-Date).AddHours(-1).ToString('o')
                replay_directory = 'D:\cached-replay'
                plan = $cachedPlan
            }
        )

        $result = Resolve-ReplayConfigurationPlan -RootDir $repoRoot -Server 'vpn.ntut.edu.tw' -UserName '113598087' -CredentialFile (Join-Path $repoRoot 'vpn_cred.xml') -CachePath $cachePath -OutputRoot (Join-Path $TestDrive 'http-replay') -TtlHours 24 -LogPath (Join-Path $TestDrive 'vpn_history.log')

        $result.Status | Should Be 'ready'
        $result.Source | Should Be 'replay_cache'
        $result.Plan.Gateway | Should Be '140.124.4.100'
        $result.ReplayDirectory | Should Be 'D:\cached-replay'
    }

    It 'keeps replay cache entries distinct when the gateway differs' {
        $cachePath = Join-Path $TestDrive 'vpn_config_cache.json'
        $entryA = [pscustomobject]@{
            username = '113598087'
            server = 'vpn.ntut.edu.tw'
            gateway = '140.124.4.100'
            captured_at = (Get-Date).AddHours(-1).ToString('o')
            replay_directory = 'D:\cached-replay-a'
            plan = (New-NetworkConfigurationPlan -AssignedIp '172.24.232.111' -PrefixLength 32 -Gateway '140.124.4.100' -DnsServers @('140.124.13.1'))
        }
        $entryB = [pscustomobject]@{
            username = '113598087'
            server = 'vpn.ntut.edu.tw'
            gateway = '140.124.4.101'
            captured_at = (Get-Date).AddMinutes(-30).ToString('o')
            replay_directory = 'D:\cached-replay-b'
            plan = (New-NetworkConfigurationPlan -AssignedIp '172.24.232.112' -PrefixLength 32 -Gateway '140.124.4.101' -DnsServers @('140.124.13.2'))
        }

        Save-ReplayConfigurationCacheEntries -CachePath $cachePath -Entries @($entryA)
        Update-ReplayConfigurationCacheEntry -CachePath $cachePath -Entry $entryB

        $entries = @(Get-ReplayConfigurationCacheEntries -CachePath $cachePath)
        $entries.Count | Should Be 2

        $selected = Get-ReplayConfigurationCacheEntry -CachePath $cachePath -UserName '113598087' -Server 'vpn.ntut.edu.tw' -Gateway '140.124.4.101'
        $selected.gateway | Should Be '140.124.4.101'
        $selected.replay_directory | Should Be 'D:\cached-replay-b'
    }

    It 'marks preview incomplete when replay-derived config is unavailable' {
        $state = [hashtable]::Synchronized(@{
            SessionState = 'connected'
            ConnectedAt = Get-Date
            AssignedIp = $null
            SessionExpiresAt = $null
            Gateway = $null
            ProcessId = 222
            TransportMode = 'esp'
            TransportChangedAt = Get-Date
            LastTransportEvent = 'esp_established'
            LastTransportEventAt = Get-Date
            LastRekeyAt = $null
            LastHipCheckAt = $null
            LastDpdOkAt = $null
            NetworkConfigEvidence = New-NetworkConfigurationEvidence
            PreConnectDnsSnapshot = @{}
            PreConnectRouteSnapshot = @()
            NetworkConfigStatus = 'not_ready'
            NetworkConfigSource = 'server_derived'
            NetworkConfigError = $null
            NetworkConfigPlan = $null
            NetworkConflicts = @()
            NetworkConfigLastUpdated = $null
            NetworkConfigRouteApplied = $false
            ReplayConfigResolution = [pscustomobject]@{
                Status = 'unavailable'
                Source = 'replay'
                Plan = $null
                Error = 'Replay failed and no fresh cache is available.'
            }
            HttpCapture = New-OpenConnectHttpCaptureState -Enabled $false
        })

        Update-NetworkConfigurationPreviewState -State $state -ServiceState 'running' -Reason 'connected' -LogPath (Join-Path $TestDrive 'vpn_history.log')

        $state.NetworkConfigStatus | Should Be 'incomplete'
        $state.NetworkConfigSource | Should Be 'replay'
        $state.NetworkConfigError | Should Match 'Replay failed'
        $state.NetworkConfigRouteApplied | Should Be $false
    }

    It 'keeps adapter-present conflicts as warnings when no DNS or route takeover evidence exists' {
        $plan = New-NetworkConfigurationPlan -AssignedIp '172.24.232.72' -PrefixLength 32 -Gateway '140.124.4.100' -SplitIncludeDomains @('*.ieee.org')
        $context = New-NetworkConfigurationContext -RootDir $repoRoot -LogPath (Join-Path $TestDrive 'vpn_history.log') -StatePath (Join-Path $TestDrive 'vpn_state.json')

        Mock -CommandName Get-NetAdapter -MockWith {
            @([pscustomobject]@{
                Name = 'OpenVPN TAP'
                InterfaceDescription = 'TAP-Windows Adapter V9 for OpenVPN Connect'
                Status = 'Up'
                InterfaceIndex = 10
            })
        }

        Mock -CommandName Get-DnsClientServerAddress -MockWith { @() }
        Mock -CommandName Get-NetRoute -MockWith { @() }

        $result = Invoke-NetworkConfigurationPreview -Plan $plan -Context $context

        $result.Status | Should Be 'incomplete'
        $result.Conflicts.Count | Should Be 0
    }

    It 'records self-managed DNS ownership when the target adapter gained DNS after connect' {
        $plan = New-NetworkConfigurationPlan -AssignedIp '172.24.232.72' -PrefixLength 32 -Gateway '140.124.4.100' -DnsServers @('140.124.13.1', '140.124.13.2') -SplitIncludeDomains @('*.ieee.org') -InterfaceHints @("'區域連線' (index 18)")
        $context = New-NetworkConfigurationContext -RootDir $repoRoot -LogPath (Join-Path $TestDrive 'vpn_history.log') -StatePath (Join-Path $TestDrive 'vpn_state.json')

        Mock -CommandName Get-NetAdapter -MockWith {
            @([pscustomobject]@{
                Name = '區域連線'
                InterfaceDescription = 'TAP-Windows Adapter V9 for OpenVPN Connect'
                Status = 'Up'
                InterfaceIndex = 18
            })
        }

        Mock -CommandName Get-DnsClientServerAddress -MockWith {
            @([pscustomobject]@{
                InterfaceIndex = 18
                ServerAddresses = @('140.124.13.1', '140.124.13.2')
            })
        }

        Mock -CommandName Get-NetRoute -MockWith { @() }

        $result = Invoke-NetworkConfigurationPreview -Plan $plan -Context $context -PreConnectDnsSnapshot @{ '18' = @() }

        $result.Status | Should Be 'ready'
        $result.Plan.DnsTargetInterfaceIndex | Should Be 18
        $result.Plan.DnsOwnedServers.Count | Should Be 2
        (@($result.Conflicts | Where-Object { $_.Kind -eq 'dns_self_managed' })).Count | Should Be 1
    }

    It 'infers the current OpenConnect adapter from matching DNS and routes when replay config has no interface hints' {
        $route = New-NetworkConfigurationRoute -Destination '140.124.0.0' -PrefixLength 16 -RouteType 'include'
        $plan = New-NetworkConfigurationPlan -AssignedIp '172.24.232.47' -PrefixLength 32 -Gateway '140.124.4.100' -DnsServers @('140.124.13.1', '140.124.13.2') -SplitIncludeRoutes @($route)
        $context = New-NetworkConfigurationContext -RootDir $repoRoot -LogPath (Join-Path $TestDrive 'vpn_history.log') -StatePath (Join-Path $TestDrive 'vpn_state.json')

        Mock -CommandName Get-NetAdapter -MockWith {
            @(
                [pscustomobject]@{
                    Name = 'OpenVPN TAP'
                    InterfaceDescription = 'TAP-Windows Adapter V9 for OpenVPN Connect'
                    Status = 'Up'
                    InterfaceIndex = 18
                },
                [pscustomobject]@{
                    Name = 'vpn.ntut.edu.tw'
                    InterfaceDescription = 'OpenConnect Wintun Userspace Tunnel'
                    Status = 'Up'
                    InterfaceIndex = 62
                }
            )
        }

        Mock -CommandName Get-DnsClientServerAddress -MockWith {
            @(
                [pscustomobject]@{
                    InterfaceIndex = 18
                    ServerAddresses = @()
                },
                [pscustomobject]@{
                    InterfaceIndex = 62
                    ServerAddresses = @('140.124.13.1', '140.124.13.2')
                }
            )
        }

        Mock -CommandName Get-NetRoute -MockWith {
            @([pscustomobject]@{
                DestinationPrefix = '140.124.0.0/16'
                InterfaceIndex = 62
                NextHop = '0.0.0.0'
                RouteMetric = 1
            })
        }

        $result = Invoke-NetworkConfigurationPreview -Plan $plan -Context $context -PreConnectDnsSnapshot @{ '18' = @(); '62' = @() } -PreConnectRouteSnapshot @()

        $result.Status | Should Be 'ready'
        $result.Plan.DnsTargetAdapter | Should Be 'vpn.ntut.edu.tw'
        $result.Plan.DnsTargetInterfaceIndex | Should Be 62
        $result.Plan.RouteTargetInterfaceIndex | Should Be 62
        (@($result.Conflicts | Where-Object { $_.Kind -eq 'dns_already_managed' -and $_.Scope -eq 'vpn.ntut.edu.tw' })).Count | Should Be 0
        (@($result.Conflicts | Where-Object { $_.Kind -eq 'dns_self_managed' -and $_.Scope -eq 'vpn.ntut.edu.tw' })).Count | Should Be 1
    }

    It 'blocks when the target adapter already had manual DNS before connect' {
        $plan = New-NetworkConfigurationPlan -AssignedIp '172.24.232.72' -PrefixLength 32 -Gateway '140.124.4.100' -DnsServers @('140.124.13.1', '140.124.13.2') -SplitIncludeDomains @('*.ieee.org') -InterfaceHints @("'區域連線' (index 18)")
        $context = New-NetworkConfigurationContext -RootDir $repoRoot -LogPath (Join-Path $TestDrive 'vpn_history.log') -StatePath (Join-Path $TestDrive 'vpn_state.json')

        Mock -CommandName Get-NetAdapter -MockWith {
            @([pscustomobject]@{
                Name = '區域連線'
                InterfaceDescription = 'TAP-Windows Adapter V9 for OpenVPN Connect'
                Status = 'Up'
                InterfaceIndex = 18
            })
        }

        Mock -CommandName Get-DnsClientServerAddress -MockWith {
            @([pscustomobject]@{
                InterfaceIndex = 18
                ServerAddresses = @('1.1.1.1')
            })
        }

        Mock -CommandName Get-NetRoute -MockWith { @() }

        $result = Invoke-NetworkConfigurationPreview -Plan $plan -Context $context -PreConnectDnsSnapshot @{ '18' = @('1.1.1.1') }

        $result.Status | Should Be 'conflict_detected'
        (@($result.Conflicts | Where-Object { $_.Kind -eq 'dns_preexisting_manual' -and $_.Severity -eq 'blocking' })).Count | Should Be 1
    }

    It 'detects owned split routes that appeared after connect' {
        $route = New-NetworkConfigurationRoute -Destination '140.124.0.0' -PrefixLength 16 -RouteType 'include'
        $plan = New-NetworkConfigurationPlan -AssignedIp '172.24.232.72' -PrefixLength 32 -Gateway '140.124.4.100' -SplitIncludeRoutes @($route) -SplitIncludeDomains @('*.ieee.org') -InterfaceHints @("'區域連線' (index 18)")
        $context = New-NetworkConfigurationContext -RootDir $repoRoot -LogPath (Join-Path $TestDrive 'vpn_history.log') -StatePath (Join-Path $TestDrive 'vpn_state.json')

        Mock -CommandName Get-NetAdapter -MockWith {
            @([pscustomobject]@{
                Name = '區域連線'
                InterfaceDescription = 'TAP-Windows Adapter V9 for OpenVPN Connect'
                Status = 'Up'
                InterfaceIndex = 18
            })
        }

        Mock -CommandName Get-DnsClientServerAddress -MockWith { @() }
        Mock -CommandName Get-NetRoute -MockWith {
            @([pscustomobject]@{
                DestinationPrefix = '140.124.0.0/16'
                InterfaceIndex = 18
                NextHop = '0.0.0.0'
                RouteMetric = 1
            })
        }

        $result = Invoke-NetworkConfigurationPreview -Plan $plan -Context $context -PreConnectDnsSnapshot @{ '18' = @() } -PreConnectRouteSnapshot @()

        $result.Status | Should Be 'ready'
        $result.Plan.RouteOwnedEntries.Count | Should Be 1
        $result.Plan.RouteCandidateEntries.Count | Should Be 0
    }

    It 'treats current target-interface routes as session-owned even when the same prefix existed on a different baseline interface' {
        $route = New-NetworkConfigurationRoute -Destination '140.124.0.0' -PrefixLength 16 -RouteType 'include'
        $plan = New-NetworkConfigurationPlan -AssignedIp '172.24.232.72' -PrefixLength 32 -Gateway '140.124.4.100' -DnsServers @('140.124.13.1', '140.124.13.2') -SplitIncludeRoutes @($route)
        $context = New-NetworkConfigurationContext -RootDir $repoRoot -LogPath (Join-Path $TestDrive 'vpn_history.log') -StatePath (Join-Path $TestDrive 'vpn_state.json')

        Mock -CommandName Get-NetAdapter -MockWith {
            @(
                [pscustomobject]@{
                    Name = 'OpenVPN TAP'
                    InterfaceDescription = 'TAP-Windows Adapter V9 for OpenVPN Connect'
                    Status = 'Up'
                    InterfaceIndex = 18
                },
                [pscustomobject]@{
                    Name = 'vpn.ntut.edu.tw'
                    InterfaceDescription = 'OpenConnect Wintun Userspace Tunnel'
                    Status = 'Up'
                    InterfaceIndex = 62
                }
            )
        }

        Mock -CommandName Get-DnsClientServerAddress -MockWith {
            @(
                [pscustomobject]@{
                    InterfaceIndex = 18
                    ServerAddresses = @()
                },
                [pscustomobject]@{
                    InterfaceIndex = 62
                    ServerAddresses = @('140.124.13.1', '140.124.13.2')
                }
            )
        }

        Mock -CommandName Get-NetRoute -MockWith {
            @(
                [pscustomobject]@{
                    DestinationPrefix = '140.124.0.0/16'
                    InterfaceIndex = 18
                    NextHop = '0.0.0.0'
                    RouteMetric = 1
                },
                [pscustomobject]@{
                    DestinationPrefix = '140.124.0.0/16'
                    InterfaceIndex = 62
                    NextHop = '0.0.0.0'
                    RouteMetric = 1
                }
            )
        }

        $baselineRoute = [pscustomobject]@{
            DestinationPrefix = '140.124.0.0/16'
            InterfaceIndex = 18
            NextHop = '0.0.0.0'
            RouteMetric = 1
        }

        $result = Invoke-NetworkConfigurationPreview -Plan $plan -Context $context -PreConnectDnsSnapshot @{ '18' = @(); '62' = @() } -PreConnectRouteSnapshot @($baselineRoute)

        $result.Status | Should Be 'ready'
        $result.Plan.RouteTargetInterfaceIndex | Should Be 62
        $result.Plan.RouteOwnedEntries.Count | Should Be 1
        (@($result.Conflicts | Where-Object { $_.Kind -eq 'route_preexisting_manual' -and $_.Scope -eq '140.124.0.0/16' })).Count | Should Be 0
    }

    It 'treats current include routes as session-owned even when the active route next hop differs from 0.0.0.0' {
        $route = New-NetworkConfigurationRoute -Destination '211.78.81.233' -PrefixLength 32 -RouteType 'include'
        $plan = New-NetworkConfigurationPlan -AssignedIp '172.24.232.72' -PrefixLength 32 -Gateway '140.124.4.100' -DnsServers @('140.124.13.1', '140.124.13.2') -SplitIncludeRoutes @($route)
        $context = New-NetworkConfigurationContext -RootDir $repoRoot -LogPath (Join-Path $TestDrive 'vpn_history.log') -StatePath (Join-Path $TestDrive 'vpn_state.json')

        Mock -CommandName Get-NetAdapter -MockWith {
            @([pscustomobject]@{
                Name = 'vpn.ntut.edu.tw'
                InterfaceDescription = 'OpenConnect Wintun Userspace Tunnel'
                Status = 'Up'
                InterfaceIndex = 62
            })
        }

        Mock -CommandName Get-DnsClientServerAddress -MockWith {
            @([pscustomobject]@{
                InterfaceIndex = 62
                ServerAddresses = @('140.124.13.1', '140.124.13.2')
            })
        }

        Mock -CommandName Get-NetRoute -MockWith {
            @([pscustomobject]@{
                DestinationPrefix = '211.78.81.233/32'
                InterfaceIndex = 62
                NextHop = '172.24.232.62'
                RouteMetric = 1
            })
        }

        $result = Invoke-NetworkConfigurationPreview -Plan $plan -Context $context -PreConnectDnsSnapshot @{ '62' = @() } -PreConnectRouteSnapshot @()

        $result.Status | Should Be 'ready'
        $result.Plan.RouteOwnedEntries.Count | Should Be 1
        $result.Plan.RouteCandidateEntries.Count | Should Be 0
        (@($result.Conflicts | Where-Object { $_.Kind -eq 'route_overlap' -and $_.Scope -eq '211.78.81.233/32' })).Count | Should Be 0
    }

    It 'blocks when a split route existed before connect' {
        $route = New-NetworkConfigurationRoute -Destination '140.124.0.0' -PrefixLength 16 -RouteType 'include'
        $plan = New-NetworkConfigurationPlan -AssignedIp '172.24.232.72' -PrefixLength 32 -Gateway '140.124.4.100' -SplitIncludeRoutes @($route) -SplitIncludeDomains @('*.ieee.org') -InterfaceHints @("'區域連線' (index 18)")
        $context = New-NetworkConfigurationContext -RootDir $repoRoot -LogPath (Join-Path $TestDrive 'vpn_history.log') -StatePath (Join-Path $TestDrive 'vpn_state.json')

        Mock -CommandName Get-NetAdapter -MockWith {
            @([pscustomobject]@{
                Name = '區域連線'
                InterfaceDescription = 'TAP-Windows Adapter V9 for OpenVPN Connect'
                Status = 'Up'
                InterfaceIndex = 18
            })
        }

        Mock -CommandName Get-DnsClientServerAddress -MockWith { @() }
        Mock -CommandName Get-NetRoute -MockWith { @() }

        $baselineRoute = [pscustomobject]@{
            DestinationPrefix = '140.124.0.0/16'
            InterfaceIndex = 18
            NextHop = '0.0.0.0'
            RouteMetric = 1
        }

        $result = Invoke-NetworkConfigurationPreview -Plan $plan -Context $context -PreConnectDnsSnapshot @{ '18' = @() } -PreConnectRouteSnapshot @($baselineRoute)

        $result.Status | Should Be 'conflict_detected'
        (@($result.Conflicts | Where-Object { $_.Kind -eq 'route_preexisting_manual' -and $_.Severity -eq 'blocking' })).Count | Should Be 1
    }

    It 'applies missing candidate split routes via New-NetRoute' {
        $route = New-NetworkConfigurationRoute -Destination '140.124.0.0' -PrefixLength 16 -RouteType 'include' -InterfaceIndex 18 -NextHop '0.0.0.0' -RouteMetric 1
        $plan = New-NetworkConfigurationPlan -RouteCandidateEntries @($route)

        Mock -CommandName New-NetRoute {}

        $appliedRoutes = @(Invoke-NetworkConfigurationRouteApply -Plan $plan -LogPath (Join-Path $TestDrive 'vpn_history.log'))

        Assert-MockCalled -CommandName New-NetRoute -Times 1 -ParameterFilter { $DestinationPrefix -eq '140.124.0.0/16' -and $InterfaceIndex -eq 18 -and $NextHop -eq '0.0.0.0' }
        $appliedRoutes.Count | Should Be 1
    }

    It 'treats already-present include routes as idempotent during route apply' {
        $route = New-NetworkConfigurationRoute -Destination '23.193.80.111' -PrefixLength 32 -RouteType 'include' -InterfaceIndex 25 -NextHop '0.0.0.0' -RouteMetric 1
        $plan = New-NetworkConfigurationPlan -RouteCandidateEntries @($route)

        Mock -CommandName New-NetRoute -MockWith { throw 'The object already exists.' }
        Mock -CommandName Get-NetRoute -MockWith {
            [pscustomobject]@{
                DestinationPrefix = '23.193.80.111/32'
                InterfaceIndex = 25
                NextHop = '23.193.80.111'
                RouteMetric = 1
            }
        }

        $appliedRoutes = @(Invoke-NetworkConfigurationRouteApply -Plan $plan -LogPath (Join-Path $TestDrive 'vpn_history.log'))

        $appliedRoutes.Count | Should Be 1
        $appliedRoutes[0].OwnershipSource | Should Be 'session_detected'
    }

    It 'marks the preview as conflict_detected when a VPN-like adapter or overlapping route exists' {
        $route = New-NetworkConfigurationRoute -Destination '140.124.0.0' -PrefixLength 16 -RouteType 'include'
        $plan = New-NetworkConfigurationPlan -AssignedIp '172.24.232.72' -PrefixLength 32 -Gateway '140.124.4.100' -DnsServers @('8.8.8.8') -SplitIncludeRoutes @($route)
        $context = New-NetworkConfigurationContext -RootDir $repoRoot -LogPath (Join-Path $TestDrive 'vpn_history.log') -StatePath (Join-Path $TestDrive 'vpn_state.json')

        Mock -CommandName Get-NetAdapter -MockWith {
            @([pscustomobject]@{
                Name = 'OpenVPN TAP'
                InterfaceDescription = 'TAP-Windows Adapter'
                Status = 'Up'
                InterfaceIndex = 10
            })
        }

        Mock -CommandName Get-DnsClientServerAddress -MockWith {
            @([pscustomobject]@{
                InterfaceIndex = 10
                ServerAddresses = @('1.1.1.1')
            })
        }

        Mock -CommandName Get-NetRoute -MockWith {
            @([pscustomobject]@{
                DestinationPrefix = '140.124.0.0/16'
                InterfaceIndex = 10
            })
        }

        $result = Invoke-NetworkConfigurationPreview -Plan $plan -Context $context -PreConnectDnsSnapshot @{ '10' = @('1.1.1.1') }

        $result.Status | Should Be 'conflict_detected'
        $result.Conflicts.Count | Should BeGreaterThan 0
        (@($result.Conflicts | Where-Object { $_.Severity -eq 'blocking' })).Count | Should BeGreaterThan 0
    }
}

Describe 'AutoVPN_Service session markers' {
    It 'does not treat HTTPS transport establishment as a connected VPN session' {
        (Test-OpenConnectConnectedLine -Line 'Connected to HTTPS on 140.124.4.100:443') | Should Be $false
    }

    It 'detects explicit GlobalProtect authentication failure markers' {
        (Test-OpenConnectAuthFailureLine -Line 'X-Private-Pan-Globalprotect: auth-failed') | Should Be $true
        (Test-OpenConnectAuthFailureLine -Line 'Unexpected 512 result from server') | Should Be $true
    }

    It 'detects explicit network failure markers' {
        (Test-OpenConnectNetworkFailureEvidence -Line 'getaddrinfo failed for host ''vpn.ntut.edu.tw'': host could not be resolved') | Should Be $true
        (Test-OpenConnectNetworkFailureEvidence -Line 'Failed to open HTTPS connection to vpn.ntut.edu.tw') | Should Be $true
    }

    It 'parses OpenConnect event timestamps' {
        $timestamp = Get-OpenConnectEventTimestamp -Line '[2026-04-03 02:04:31] GlobalProtect rekey due'

        $timestamp | Should Be ([datetime]'2026-04-03 02:04:31')
    }

    It 'detects vpnc-script command failures and builds a concise summary' {
        $line = '[vpnc-script][connect][run] Command failed with exit 1: netsh interface ipv4 add dnsservers 18 1.1.1.1 validate=no'

        (Test-OpenConnectScriptWarningLine -Line $line) | Should Be $true
        (Get-OpenConnectScriptWarningSummary -Line $line) | Should Match 'Command=netsh interface ipv4 add dnsservers 18 1.1.1.1 validate=no'
    }

    It 'detects vpnc-script timeout checkpoint warnings' {
        $line = '[2026-04-03 14:27:40] Script did not complete within 10 seconds.'

        (Test-OpenConnectScriptWarningLine -Line $line) | Should Be $true
        (Get-OpenConnectScriptWarningSummary -Line $line) | Should Match 'completion window'
    }
}

Describe 'AutoVPN_Service reconnect policy' {
    It 'returns the next session reconnect delay from the configured schedule' {
        $action = Get-NextSessionReconnectAction -DelaysSeconds @(10, 30) -AttemptIndex 0

        $action.ShouldRetry | Should Be $true
        $action.DelaySeconds | Should Be 10
        $action.NextAttemptIndex | Should Be 1
    }

    It 'stops retrying after the configured session reconnect schedule is exhausted' {
        $action = Get-NextSessionReconnectAction -DelaysSeconds @(10, 30) -AttemptIndex 2

        $action.ShouldRetry | Should Be $false
        $action.DelaySeconds | Should Be $null
        $action.NextAttemptIndex | Should Be 2
    }
}

Describe 'AutoVPN_Service startup guard' {
    BeforeEach {
        $script:StateFile = Join-Path $TestDrive 'vpn_state.json'
        $script:StopRequestFile = Join-Path $TestDrive 'vpn_stop_requested.flag'
    }

    It 'blocks startup when a protective startup lock is present' {
        Write-VpnRuntimeState -StatePath $script:StateFile -ServiceState 'blocked' -SessionState 'stopped' -Reason 'Authentication/setup failure' -ServicePid 1000 -OpenConnectPid 0 -ConnectedAt $null -StartupBlocked $true -StartupBlockCategory 'auth_failure'

        $decision = Test-StartupAllowed

        $decision.Allowed | Should Be $false
        $decision.Category | Should Be 'auth_failure'
        $decision.Message | Should Match 'Run Stop_VPN\.bat'
    }

    It 'preserves startup lock fields when runtime state is updated without explicit override' {
        Write-VpnRuntimeState -StatePath $script:StateFile -ServiceState 'blocked' -SessionState 'stopped' -Reason 'Initial connection failed before session establishment' -ServicePid 1000 -OpenConnectPid 0 -ConnectedAt $null -StartupBlocked $true -StartupBlockCategory 'connect_failure'

        Update-ServiceRuntimeState -ServiceState 'stopped' -SessionState 'stopped' -Reason 'VPN monitor stopping. Reason=Initial connection failed before session establishment' -OpenConnectPid 0 -ConnectedAt $null
        $state = Read-VpnRuntimeState -StatePath $script:StateFile

        $state.startup_blocked | Should Be $true
        $state.startup_block_category | Should Be 'connect_failure'
    }

    It 'generates a stable startup mutex name for the workspace' {
        $name = Get-VpnStartupMutexName -WorkspacePath $TestDrive

        $name | Should Match '^Global\\NTUT_AutoConnectVPN_'
    }

    It 'suppresses late running-state rewrites after a stop request sentinel is present' {
        Write-VpnRuntimeState -StatePath $script:StateFile -ServiceState 'stopped' -SessionState 'stopped' -Reason 'Startup protection cleared by Stop_VPN.bat.' -ServicePid 0 -OpenConnectPid 0 -ConnectedAt $null -StartupBlocked $false -StartupBlockCategory $null
        Set-VpnStopRequest -RequestPath $script:StopRequestFile

        Update-ServiceRuntimeState -ServiceState 'running' -SessionState 'connected' -Reason 'ESP session established with server' -OpenConnectPid 4321 -ConnectedAt (Get-Date) -AssignedIp '172.24.232.47' -Gateway '140.124.4.100'
        $state = Read-VpnRuntimeState -StatePath $script:StateFile

        $state.service_state | Should Be 'stopped'
        $state.session_state | Should Be 'stopped'
        $state.reason | Should Match 'Stop_VPN'
        $state.openconnect_pid | Should Be $null
    }
}

Describe 'AutoVPN_Service generic process supervision' {
    BeforeEach {
        $script:logPath = Join-Path $TestDrive 'vpn_history.log'
        $script:rawLogPath = Join-Path $TestDrive 'vpn_openconnect_raw.log'
        $env:LOGFILE = $script:logPath
        $script:LogFile = $script:logPath
        $script:OpenConnectRawLogFile = $script:rawLogPath
        $script:StateFile = Join-Path $TestDrive 'vpn_state.json'
    }

    It 'captures stdout and stderr lines from a supervised child process and recognizes tunnel-established output' {
        $childScript = Join-Path $TestDrive 'child-output.ps1'
        @(
            'Write-Output "ESP session established with server"',
            'Write-Output "stdout line"',
            '[Console]::Error.WriteLine("stderr line")',
            'Start-Sleep -Milliseconds 500',
            'exit 0'
        ) | Set-Content -Path $childScript

        $result = Invoke-SupervisedProcess -Executable 'powershell.exe' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScript) -Component 'test-child' -DisplayArguments $childScript -InitialObservationSeconds 0 -HeartbeatSeconds 1 -LogPath $script:logPath

        $result.Classification | Should Be 'session_exit'
        $logContent = Get-Content -Path $script:logPath -Raw
        $rawContent = Get-Content -Path $script:rawLogPath -Raw
        $logContent | Should Match '\[supervisor\]\[state\] test-child State transition: launching -> connected'
        $rawContent | Should Match '\[test-child\]\[stdout\] stdout line'
        $rawContent | Should Match '\[test-child\]\[stderr\] stderr line'
    }

    It 'emits supervisor heartbeat logs for a long-running child process' {
        $childScript = Join-Path $TestDrive 'child-heartbeat.ps1'
        @(
            'Write-Output "ESP session established with server"',
            'Start-Sleep -Seconds 4',
            'Write-Output "done"',
            'exit 0'
        ) | Set-Content -Path $childScript

        $result = Invoke-SupervisedProcess -Executable 'powershell.exe' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScript) -Component 'heartbeat-child' -DisplayArguments $childScript -InitialObservationSeconds 0 -HeartbeatSeconds 1 -LogPath $script:logPath

        $result.Classification | Should Be 'session_exit'
        $logContent = Get-Content -Path $script:logPath -Raw
        $logContent | Should Match '\[supervisor\]\[heartbeat\]'
    }

    It 'classifies exits before a connected marker as connect_failure after progress output' {
        $childScript = Join-Path $TestDrive 'child-connect-failure.ps1'
        @(
            'Write-Output "Attempting to connect to server 140.124.4.100:443"',
            'Start-Sleep -Seconds 1',
            'exit 9'
        ) | Set-Content -Path $childScript

        $result = Invoke-SupervisedProcess -Executable 'powershell.exe' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScript) -Component 'connect-failure-child' -DisplayArguments $childScript -InitialObservationSeconds 0 -HeartbeatSeconds 1 -LogPath $script:logPath

        $result.Classification | Should Be 'connect_failure'
        $result.SessionState | Should Be 'authenticating'
        $result.ExitCode | Should Be 9
    }

    It 'classifies GlobalProtect auth-failed output as auth_failure even after HTTPS transport is up' {
        $childScript = Join-Path $TestDrive 'child-auth-failure.ps1'
        @(
            'Write-Output "Connected to HTTPS on 140.124.4.100:443"',
            'Write-Output "X-Private-Pan-Globalprotect: auth-failed"',
            '[Console]::Error.WriteLine("Unexpected 512 result from server")',
            '[Console]::Error.WriteLine("Failed to complete authentication")',
            'exit 1'
        ) | Set-Content -Path $childScript

        $result = Invoke-SupervisedProcess -Executable 'powershell.exe' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScript) -Component 'auth-failure-child' -DisplayArguments $childScript -InitialObservationSeconds 0 -HeartbeatSeconds 1 -LogPath $script:logPath

        $result.Classification | Should Be 'auth_failure'
        $result.SessionState | Should Be 'authenticating'
    }

    It 'classifies immediate exits before the stable window as unknown_failure when evidence is incomplete' {
        $childScript = Join-Path $TestDrive 'child-immediate-exit.ps1'
        'exit 7' | Set-Content -Path $childScript

        $result = Invoke-SupervisedProcess -Executable 'powershell.exe' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScript) -Component 'immediate-child' -DisplayArguments $childScript -InitialObservationSeconds 1 -HeartbeatSeconds 1 -LogPath $script:logPath

        $result.Classification | Should Be 'unknown_failure'
        $result.ExitCode | Should Be 7
    }

    It 'classifies explicit DNS failures as network_failure before connection' {
        $childScript = Join-Path $TestDrive 'child-network-failure.ps1'
        @(
            'Write-Error "getaddrinfo failed for host ''vpn.ntut.edu.tw'': host could not be resolved"',
            'Write-Error "Failed to open HTTPS connection to vpn.ntut.edu.tw"',
            'exit 1'
        ) | Set-Content -Path $childScript

        $result = Invoke-SupervisedProcess -Executable 'powershell.exe' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScript) -Component 'network-failure-child' -DisplayArguments $childScript -InitialObservationSeconds 0 -HeartbeatSeconds 1 -LogPath $script:logPath

        $result.Classification | Should Be 'network_failure'
    }

    It 'tracks transport fallback events without changing the recovery classifier' {
        $state = [hashtable]::Synchronized(@{
            SessionState = 'connected'
            ConnectedAt = (Get-Date)
            AssignedIp = '172.24.232.72'
            SessionExpiresAt = (Get-Date).AddHours(4)
            Gateway = '140.124.4.100'
            ProcessId = 123
            TransportMode = 'esp'
            TransportChangedAt = $null
            LastTransportEvent = $null
            LastTransportEventAt = $null
            LastRekeyAt = $null
            LastHipCheckAt = $null
            LastDpdOkAt = $null
            AuthFailureDetected = $false
            NetworkFailureDetected = $false
        })

        Update-OpenConnectSessionStateFromLine -State $state -Line '[2026-04-03 02:04:31] GlobalProtect rekey due' -Component 'openconnect' -LogPath $script:logPath
        Update-OpenConnectSessionStateFromLine -State $state -Line '[2026-04-03 02:04:58] Failed to connect ESP tunnel; using HTTPS instead.' -Component 'openconnect' -LogPath $script:logPath
        Update-OpenConnectSessionStateFromLine -State $state -Line '[2026-04-03 02:05:08] Got GPST DPD/keepalive response' -Component 'openconnect' -LogPath $script:logPath

        $state.TransportMode | Should Be 'https_fallback'
        $state.LastTransportEvent | Should Be 'dpd_ok'
        $state.LastRekeyAt | Should Not Be $null
        $state.LastDpdOkAt | Should Not Be $null
        $state.SessionState | Should Be 'connected'
        $state.AuthFailureDetected | Should Be $false
        $state.NetworkFailureDetected | Should Be $false
    }

    It 'keeps connected state when delayed auth markers arrive after tunnel establishment' {
        $state = [hashtable]::Synchronized(@{
            SessionState = 'connected'
            ConnectedAt = (Get-Date)
            ProcessId = 123
            AuthFailureDetected = $false
            AuthFailureReason = $null
        })

        Update-OpenConnectSessionStateFromLine -State $state -Line '[2026-04-06 12:18:51] Unexpected 512 result from server' -Component 'openconnect' -LogPath $script:logPath
        $state.SessionState | Should Be 'connected'
        $state.AuthFailureDetected | Should Be $false

        Update-OpenConnectSessionStateFromLine -State $state -Line '[2026-04-06 12:18:51] X-Private-Pan-Globalprotect: auth-failed' -Component 'openconnect' -LogPath $script:logPath
        $state.SessionState | Should Be 'connected'
        $state.AuthFailureDetected | Should Be $false
    }

    It 'writes a high-level vpnc-script failure summary to vpn_history.log' {
        $state = [hashtable]::Synchronized(@{
            SessionState = 'authenticating'
            ConnectedAt = $null
            AssignedIp = $null
            SessionExpiresAt = $null
            Gateway = $null
            ProcessId = 123
            TransportMode = $null
            TransportChangedAt = $null
            LastTransportEvent = $null
            LastTransportEventAt = $null
            LastRekeyAt = $null
            LastHipCheckAt = $null
            LastDpdOkAt = $null
            AuthFailureDetected = $false
            NetworkFailureDetected = $false
            ScriptWarningDetected = $false
            ScriptWarningReason = $null
        })

        Update-OpenConnectSessionStateFromLine -State $state -Line '[vpnc-script][connect][run] Command failed with exit 1: netsh interface ipv4 add dnsservers 18 1.1.1.1 validate=no' -Component 'openconnect' -LogPath $script:logPath

        $state.ScriptWarningDetected | Should Be $true
        $state.ScriptWarningReason | Should Match 'Command failed with exit 1'
        $logContent = Get-Content -Path $script:logPath -Raw
        $logContent | Should Match '\[vpnc-script\]\[failure\]'
        $logContent | Should Match 'Review vpn_openconnect_raw\.log'
        $logContent | Should Not Match 'stdout\+stderr dump'
    }

    It 'passes diagnostic environment variables to the supervised child process' {
        $childScript = Join-Path $TestDrive 'child-env.ps1'
        @(
            'Write-Output ("dryRun=" + $env:VPNC_SCRIPT_DRY_RUN)',
            'Write-Output ("skipDns=" + $env:VPNC_SCRIPT_SKIP_DNS)',
            'Write-Output "ESP session established with server"',
            'exit 0'
        ) | Set-Content -Path $childScript

        $envVars = @{
            VPNC_SCRIPT_DRY_RUN = '1'
            VPNC_SCRIPT_SKIP_DNS = '1'
        }

        $result = Invoke-SupervisedProcess -Executable 'powershell.exe' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScript) -Component 'env-child' -DisplayArguments $childScript -InitialObservationSeconds 0 -HeartbeatSeconds 1 -LogPath $script:logPath -EnvironmentVariables $envVars

        $result.Classification | Should Match 'session_exit|connect_failure|unknown_failure'
        $rawContent = Get-Content -Path $script:rawLogPath -Raw
        $rawContent | Should Match '\[env-child\]\[stdout\] dryRun=1'
        $rawContent | Should Match '\[env-child\]\[stdout\] skipDns=1'
    }

    It 'routes dump-http-traffic lines into the dedicated HTTP dump log' {
        $childScript = Join-Path $TestDrive 'child-http-dump.ps1'
        $script:httpDumpPath = Join-Path $TestDrive 'vpn_openconnect_http_dump.log'
        $script:httpBodyDumpPath = Join-Path $TestDrive 'vpn_openconnect_http_body_dump.log'
        $script:OpenConnectHttpDumpFile = $script:httpDumpPath
        $script:OpenConnectHttpBodyDumpFile = $script:httpBodyDumpPath
        $script:Config_OpenConnectDumpHttpTraffic = $true

        @(
            'Write-Output "[2026-04-03 19:17:57] POST https://vpn.ntut.edu.tw/ssl-vpn/getconfig.esp"',
            'Write-Output "[2026-04-03 19:17:57] HTTP body length:  (6809)"',
            'Write-Output "ESP session established with server"',
            'exit 0'
        ) | Set-Content -Path $childScript

        $null = Invoke-SupervisedProcess -Executable 'powershell.exe' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScript) -Component 'http-dump-child' -DisplayArguments $childScript -InitialObservationSeconds 0 -HeartbeatSeconds 1 -LogPath $script:logPath

        $rawContent = Get-Content -Path $script:rawLogPath -Raw
        $httpDumpContent = Get-Content -Path $script:httpDumpPath -Raw
        $rawContent | Should Not Match 'ssl-vpn/getconfig\.esp'
        $httpDumpContent | Should Match 'ssl-vpn/getconfig\.esp'
        $httpDumpContent | Should Match 'HTTP body length'
        Test-Path $script:httpBodyDumpPath | Should Be $false
    }

    It 'tracks headers-only HTTP config evidence when no XML body is emitted' {
        $captureState = New-OpenConnectHttpCaptureState -Enabled $true
        $dumpPath = Join-Path $TestDrive 'vpn_openconnect_http_dump.log'
        $bodyDumpPath = Join-Path $TestDrive 'vpn_openconnect_http_body_dump.log'

        $null = Add-OpenConnectHttpCaptureLine -CaptureState $captureState -Component 'openconnect' -Stream 'stdout' -RawLine 'POST https://vpn.ntut.edu.tw/ssl-vpn/getconfig.esp' -NormalizedLine 'POST https://vpn.ntut.edu.tw/ssl-vpn/getconfig.esp' -DumpFile $dumpPath -BodyDumpFile $bodyDumpPath
        $null = Add-OpenConnectHttpCaptureLine -CaptureState $captureState -Component 'openconnect' -Stream 'stdout' -RawLine 'Content-Type: application/xml; charset=UTF-8' -NormalizedLine 'Content-Type: application/xml; charset=UTF-8' -DumpFile $dumpPath -BodyDumpFile $bodyDumpPath
        $null = Add-OpenConnectHttpCaptureLine -CaptureState $captureState -Component 'openconnect' -Stream 'stdout' -RawLine 'HTTP body length:  (6809)' -NormalizedLine 'HTTP body length:  (6809)' -DumpFile $dumpPath -BodyDumpFile $bodyDumpPath
        Complete-OpenConnectHttpCaptureState -CaptureState $captureState -BodyDumpFile $bodyDumpPath

        $metadata = Get-OpenConnectHttpCapturePlanMetadata -CaptureState $captureState -DumpFile $dumpPath -BodyDumpFile $bodyDumpPath

        $metadata.http_config_capture_status | Should Be 'headers_only'
        $metadata.xml_capture_blocked_reason | Should Be 'body_not_emitted_by_openconnect'
        $metadata.http_config_documents.Count | Should Be 1
        $metadata.http_config_documents[0].RequestPath | Should Be '/ssl-vpn/getconfig.esp'
        $metadata.http_config_documents[0].ParserStatus | Should Be 'not_captured'
        Test-Path $bodyDumpPath | Should Be $false
    }

    It 'captures XML body documents and records root element metadata' {
        $captureState = New-OpenConnectHttpCaptureState -Enabled $true
        $dumpPath = Join-Path $TestDrive 'vpn_openconnect_http_dump.log'
        $bodyDumpPath = Join-Path $TestDrive 'vpn_openconnect_http_body_dump.log'

        $xmlLines = @(
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<response>',
            '  <status>success</status>',
            '</response>'
        )

        $null = Add-OpenConnectHttpCaptureLine -CaptureState $captureState -Component 'openconnect' -Stream 'stdout' -RawLine 'POST https://vpn.ntut.edu.tw/global-protect/getconfig.esp' -NormalizedLine 'POST https://vpn.ntut.edu.tw/global-protect/getconfig.esp' -DumpFile $dumpPath -BodyDumpFile $bodyDumpPath
        $null = Add-OpenConnectHttpCaptureLine -CaptureState $captureState -Component 'openconnect' -Stream 'stdout' -RawLine 'Content-Type: application/xml; charset=UTF-8' -NormalizedLine 'Content-Type: application/xml; charset=UTF-8' -DumpFile $dumpPath -BodyDumpFile $bodyDumpPath
        $null = Add-OpenConnectHttpCaptureLine -CaptureState $captureState -Component 'openconnect' -Stream 'stdout' -RawLine 'HTTP body length:  (128)' -NormalizedLine 'HTTP body length:  (128)' -DumpFile $dumpPath -BodyDumpFile $bodyDumpPath
        foreach ($xmlLine in $xmlLines) {
            $null = Add-OpenConnectHttpCaptureLine -CaptureState $captureState -Component 'openconnect' -Stream 'stdout' -RawLine $xmlLine -NormalizedLine $xmlLine -DumpFile $dumpPath -BodyDumpFile $bodyDumpPath
        }
        Complete-OpenConnectHttpCaptureState -CaptureState $captureState -BodyDumpFile $bodyDumpPath

        $metadata = Get-OpenConnectHttpCapturePlanMetadata -CaptureState $captureState -DumpFile $dumpPath -BodyDumpFile $bodyDumpPath
        $bodyDumpContent = Get-Content -Path $bodyDumpPath -Raw

        $metadata.http_config_capture_status | Should Be 'body_captured'
        $metadata.xml_capture_blocked_reason | Should Be $null
        $metadata.http_config_documents.Count | Should Be 1
        $metadata.http_config_documents[0].DocumentType | Should Be 'global_protect_getconfig'
        $metadata.http_config_documents[0].RootElement | Should Be 'response'
        $metadata.http_config_documents[0].ParserStatus | Should Be 'parsed'
        $bodyDumpContent | Should Match 'BEGIN HTTP XML BODY /global-protect/getconfig\.esp'
        $bodyDumpContent | Should Match '<response>'
    }

    It 'captures prefixed OpenConnect dump XML lines into the body dump' {
        $captureState = New-OpenConnectHttpCaptureState -Enabled $true
        $dumpPath = Join-Path $TestDrive 'vpn_openconnect_http_dump.log'
        $bodyDumpPath = Join-Path $TestDrive 'vpn_openconnect_http_body_dump.log'

        $xmlLines = @(
            '< <?xml version="1.0" encoding="UTF-8" ?>',
            '< <prelogin-response>',
            '< <status>Success</status>',
            '< </prelogin-response>'
        )

        $null = Add-OpenConnectHttpCaptureLine -CaptureState $captureState -Component 'openconnect' -Stream 'stdout' -RawLine 'POST https://vpn.ntut.edu.tw/global-protect/prelogin.esp' -NormalizedLine 'POST https://vpn.ntut.edu.tw/global-protect/prelogin.esp' -DumpFile $dumpPath -BodyDumpFile $bodyDumpPath
        $null = Add-OpenConnectHttpCaptureLine -CaptureState $captureState -Component 'openconnect' -Stream 'stdout' -RawLine 'Content-Type: application/xml; charset=UTF-8' -NormalizedLine 'Content-Type: application/xml; charset=UTF-8' -DumpFile $dumpPath -BodyDumpFile $bodyDumpPath
        $null = Add-OpenConnectHttpCaptureLine -CaptureState $captureState -Component 'openconnect' -Stream 'stdout' -RawLine 'HTTP body length:  (548)' -NormalizedLine 'HTTP body length:  (548)' -DumpFile $dumpPath -BodyDumpFile $bodyDumpPath
        foreach ($xmlLine in $xmlLines) {
            $null = Add-OpenConnectHttpCaptureLine -CaptureState $captureState -Component 'openconnect' -Stream 'stdout' -RawLine $xmlLine -NormalizedLine $xmlLine -DumpFile $dumpPath -BodyDumpFile $bodyDumpPath
        }
        Complete-OpenConnectHttpCaptureState -CaptureState $captureState -BodyDumpFile $bodyDumpPath

        $metadata = Get-OpenConnectHttpCapturePlanMetadata -CaptureState $captureState -DumpFile $dumpPath -BodyDumpFile $bodyDumpPath
        $bodyDumpContent = Get-Content -Path $bodyDumpPath -Raw

        $metadata.http_config_capture_status | Should Be 'body_captured'
        $metadata.http_config_documents.Count | Should Be 1
        $metadata.http_config_documents[0].DocumentType | Should Be 'global_protect_prelogin'
        $metadata.http_config_documents[0].RootElement | Should Be 'prelogin-response'
        $bodyDumpContent | Should Match '<prelogin-response>'
        $bodyDumpContent | Should Match '<status>Success</status>'
    }
}

Describe 'AutoVPN_Service OpenConnect supervision flow' {
    BeforeEach {
        $script:logPath = Join-Path $TestDrive 'vpn_history.log'
        $env:LOGFILE = $script:logPath
        $script:LogFile = $script:logPath
        $script:statusScript = Join-Path $TestDrive 'status.ps1'
        $script:StopRequestFile = Join-Path $TestDrive 'vpn_stop_requested.flag'
        if (Test-Path $script:StopRequestFile) {
            Remove-Item -Path $script:StopRequestFile -Force
        }
        'Write-Host "status"' | Set-Content -Path $script:statusScript
        Mock -CommandName Show-StatusWindow -MockWith { }
        Mock -CommandName Stop-ExistingOpenConnectProcesses -MockWith { }
        Mock -CommandName Remove-ServicePidFile -MockWith { }
    }

    It 'maps unknown pre-connect failures without opening the status window' {
        Mock -CommandName Invoke-SupervisedProcess -MockWith {
            [PSCustomObject]@{
                Classification = 'unknown_failure'
                ProcessId = 101
                ExitCode = 3
                DurationSeconds = 1
                LastStdOut = 'prompt'
                LastStdErr = 'auth failed'
                LastActivity = Get-Date
            }
        }

        $result = Invoke-OpenConnectSession -Executable 'openconnect.exe' -Username 'user' -Password 'secret' -TargetServer 'vpn.test.com' -StatusScript $script:statusScript -PidPath (Join-Path $TestDrive 'vpn.pid')

        $result.Classification | Should Be 'unknown_failure'
        $result.ShouldRetry | Should Be $false
        Assert-MockCalled -CommandName Remove-ServicePidFile -Times 0 -Scope It
        Assert-MockCalled -CommandName Show-StatusWindow -Times 0 -Scope It
    }

    It 'maps connect_failure to a non-retry result without showing the status window' {
        Mock -CommandName Invoke-SupervisedProcess -MockWith {
            [PSCustomObject]@{
                Classification = 'connect_failure'
                ProcessId = 201
                ExitCode = 9
                DurationSeconds = 58
                LastStdOut = 'Attempting to connect to server 140.124.4.100:443'
                LastStdErr = $null
                LastActivity = Get-Date
                SessionState = 'authenticating'
            }
        }

        $result = Invoke-OpenConnectSession -Executable 'openconnect.exe' -Username 'user' -Password 'secret' -TargetServer 'vpn.test.com' -StatusScript $script:statusScript -PidPath (Join-Path $TestDrive 'vpn.pid')

        $result.Classification | Should Be 'connect_failure'
        $result.ShouldRetry | Should Be $false
        Assert-MockCalled -CommandName Show-StatusWindow -Times 0 -Scope It
        Assert-MockCalled -CommandName Remove-ServicePidFile -Times 0 -Scope It
    }

    It 'maps later child exit to session_lost and keeps reconnect enabled' {
        Mock -CommandName Invoke-SupervisedProcess -MockWith {
            [PSCustomObject]@{
                Classification = 'session_exit'
                ProcessId = 202
                ExitCode = 0
                DurationSeconds = 65
                LastStdOut = 'connected'
                LastStdErr = $null
                LastActivity = Get-Date
                SessionState = 'connected'
            }
        }

        $result = Invoke-OpenConnectSession -Executable 'openconnect.exe' -Username 'user' -Password 'secret' -TargetServer 'vpn.test.com' -StatusScript $script:statusScript -PidPath (Join-Path $TestDrive 'vpn.pid')

        $result.Classification | Should Be 'session_lost'
        $result.ShouldRetry | Should Be $true
        Assert-MockCalled -CommandName Stop-ExistingOpenConnectProcesses -Times 2 -Scope It
    }

    It 'maps auth_failure to auth_failure without opening the status window' {
        Mock -CommandName Invoke-SupervisedProcess -MockWith {
            [PSCustomObject]@{
                Classification = 'auth_failure'
                ProcessId = 301
                ExitCode = 1
                DurationSeconds = 5
                LastStdOut = 'X-Private-Pan-Globalprotect: auth-failed'
                LastStdErr = 'Unexpected 512 result from server'
                LastActivity = Get-Date
                SessionState = 'authenticating'
            }
        }

        $result = Invoke-OpenConnectSession -Executable 'openconnect.exe' -Username 'user' -Password 'secret' -TargetServer 'vpn.test.com' -StatusScript $script:statusScript -PidPath (Join-Path $TestDrive 'vpn.pid')

        $result.Classification | Should Be 'auth_failure'
        $result.ShouldRetry | Should Be $false
        Assert-MockCalled -CommandName Show-StatusWindow -Times 0 -Scope It
    }

    It 'maps network_failure to network_failure without opening the status window' {
        Mock -CommandName Invoke-SupervisedProcess -MockWith {
            [PSCustomObject]@{
                Classification = 'network_failure'
                ProcessId = 302
                ExitCode = 1
                DurationSeconds = 5
                LastStdOut = 'POST https://vpn.ntut.edu.tw/global-protect/prelogin.esp'
                LastStdErr = 'Failed to open HTTPS connection to vpn.ntut.edu.tw'
                LastActivity = Get-Date
                SessionState = 'authenticating'
            }
        }

        $result = Invoke-OpenConnectSession -Executable 'openconnect.exe' -Username 'user' -Password 'secret' -TargetServer 'vpn.test.com' -StatusScript $script:statusScript -PidPath (Join-Path $TestDrive 'vpn.pid')

        $result.Classification | Should Be 'network_failure'
        $result.ShouldRetry | Should Be $false
        Assert-MockCalled -CommandName Show-StatusWindow -Times 0 -Scope It
    }

    It 'suppresses reconnect handling when a stop request sentinel is present after supervised exit' {
        Set-VpnStopRequest -RequestPath $script:StopRequestFile
        Mock -CommandName Invoke-SupervisedProcess -MockWith {
            [PSCustomObject]@{
                Classification = 'session_exit'
                ProcessId = 909
                ExitCode = 0
                DurationSeconds = 65
                LastStdOut = 'connected'
                LastStdErr = $null
                LastActivity = Get-Date
                SessionState = 'connected'
            }
        }

        $result = Invoke-OpenConnectSession -Executable 'openconnect.exe' -Username 'user' -Password 'secret' -TargetServer 'vpn.test.com' -StatusScript $script:statusScript -PidPath (Join-Path $TestDrive 'vpn.pid')

        $result.Classification | Should Be 'stop_requested'
        $result.ShouldRetry | Should Be $false
        Assert-MockCalled -CommandName Stop-ExistingOpenConnectProcesses -Times 1 -Scope It
    }

    It 'includes script warning evidence in the summary log for failed sessions' {
        Mock -CommandName Invoke-SupervisedProcess -MockWith {
            [PSCustomObject]@{
                Classification = 'unknown_failure'
                ProcessId = 401
                ExitCode = 1
                DurationSeconds = 8
                LastStdOut = 'Connected to HTTPS on 140.124.4.100:443'
                LastStdErr = "[2026-04-03 13:48:17] Script 'cscript.exe //Nologo //E:jscript ""D:\Application\NTUT_AutoConnectVPN\bin\vpnc-script-win.js""' returned error 1"
                LastActivity = Get-Date
                SessionState = 'authenticating'
                ScriptWarningDetected = $true
                ScriptWarningReason = "[2026-04-03 13:48:17] Script 'cscript.exe //Nologo //E:jscript ""D:\Application\NTUT_AutoConnectVPN\bin\vpnc-script-win.js""' returned error 1"
            }
        }

        $result = Invoke-OpenConnectSession -Executable 'openconnect.exe' -Username 'user' -Password 'secret' -TargetServer 'vpn.test.com' -StatusScript $script:statusScript -PidPath (Join-Path $TestDrive 'vpn.pid')

        $result.Classification | Should Be 'unknown_failure'
        $logContent = Get-Content -Path $script:logPath -Raw
        $logContent | Should Match 'ScriptWarning=.*returned error 1'
    }
}

Describe 'AutoVPN_Service notification popup' {
    It 'builds a syntactically valid PowerShell notification script' {
        $scriptText = New-ServiceNotificationScript -Title 'VPN Authentication Failed' -Message 'Users password is invalid'

        { [ScriptBlock]::Create($scriptText) } | Should Not Throw
    }

    It 'does not open a notification window when failure notifications are disabled' {
        $script:Config_ServiceFailureNotifications = $false
        Mock -CommandName Start-Process -MockWith { }

        Show-ServiceNotification -Title 'VPN Authentication Failed' -Message 'Users password is invalid' -LogPath $script:logPath

        Assert-MockCalled -CommandName Start-Process -Times 0 -Scope It
    }

    It 'opens the connected review status window when interactive output is enabled' {
        $script:Config_ServiceInteractiveOutput = $true
        $statusScript = Join-Path $TestDrive 'status.ps1'
        'Write-Host "status"' | Set-Content -Path $statusScript
        Mock -CommandName Start-Process -MockWith { }

        Show-StatusWindow -StatusScript $statusScript

        Assert-MockCalled -CommandName Start-Process -Times 1 -Scope It
    }

    It 'does not open a status window when interactive output is disabled' {
        $script:Config_ServiceInteractiveOutput = $false
        $statusScript = Join-Path $TestDrive 'status.ps1'
        'Write-Host "status"' | Set-Content -Path $statusScript
        Mock -CommandName Start-Process -MockWith { }

        Show-StatusWindow -StatusScript $statusScript

        Assert-MockCalled -CommandName Start-Process -Times 0 -Scope It
    }

    It 'opens the final status window for non-zero terminal outcomes' {
        $script:Config_ServiceInteractiveOutput = $true
        $statusScript = Join-Path $TestDrive 'status.ps1'
        'Write-Host "status"' | Set-Content -Path $statusScript
        Mock -CommandName Start-Process -MockWith { }

        Show-TerminalStatusWindow -StatusScript $statusScript -ExitCode 1 -ShutdownReason 'Authentication/setup failure'

        Assert-MockCalled -CommandName Start-Process -Times 1 -Scope It
    }

    It 'does not open the final status window for clean shutdowns' {
        $script:Config_ServiceInteractiveOutput = $true
        $statusScript = Join-Path $TestDrive 'status.ps1'
        'Write-Host "status"' | Set-Content -Path $statusScript
        Mock -CommandName Start-Process -MockWith { }

        Show-TerminalStatusWindow -StatusScript $statusScript -ExitCode 0 -ShutdownReason 'Requested shutdown'

        Assert-MockCalled -CommandName Start-Process -Times 0 -Scope It
    }
}
