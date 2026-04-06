function Get-OpenConnectArguments {
    param(
        [string] $Username,
        [string] $TargetServer,
        [string] $Protocol = 'gp',
        [int] $VerboseLevel = 1,
        [bool] $TimestampOutput = $true,
        [int] $ReconnectTimeoutSeconds = 0,
        [bool] $NoDtls = $false,
        [bool] $DumpHttpTraffic = $false,
        [string] $ScriptCommand,
        [bool] $NonInteractive = $true
    )

    $ocArgs = @(
        "--protocol=$Protocol",
        "--user=$Username",
        '--passwd-on-stdin'
    )

    if ($NonInteractive) {
        $ocArgs += '--non-inter'
    }

    if ($VerboseLevel -gt 0) {
        $normalizedVerboseLevel = [Math]::Min([Math]::Max($VerboseLevel, 1), 4)
        $ocArgs += ('-' + ('v' * $normalizedVerboseLevel))
    }

    if ($TimestampOutput) {
        $ocArgs += '--timestamp'
    }

    if ($ReconnectTimeoutSeconds -gt 0) {
        $ocArgs += "--reconnect-timeout=$ReconnectTimeoutSeconds"
    }

    if ($NoDtls) {
        $ocArgs += '--no-dtls'
    }

    if ($DumpHttpTraffic) {
        $ocArgs += '--dump-http-traffic'
    }

    if (-not [string]::IsNullOrWhiteSpace($ScriptCommand)) {
        $ocArgs += "--script=$ScriptCommand"
    }

    $ocArgs += $TargetServer
    return $ocArgs
}

function Test-OpenConnectHttpDumpLine {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    $patterns = @(
        '^POST https://',
        '^GET https://',
        '^Got HTTP response:',
        '^HTTP body length:',
        '^Content-Type:',
        '^Content-Length:',
        '^Connection:',
        '^Cache-Control:',
        '^X-Frame-Options:',
        '^Strict-Transport-Security:',
        '^X-XSS-Protection:',
        '^X-Content-Type-Options:',
        '^Content-Security-Policy:'
    )

    foreach ($pattern in $patterns) {
        if ($Line -match $pattern) {
            return $true
        }
    }

    return $false
}

function Test-OpenConnectHttpRequestLine {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    return ($Line -match '^(GET|POST) https://')
}

function Get-OpenConnectHttpRequestPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    if (-not (Test-OpenConnectHttpRequestLine -Line $Line)) {
        return $null
    }

    $parts = $Line.Split(' ', 3)
    if ($parts.Count -lt 2) {
        return $null
    }

    try {
        $uri = [System.Uri] $parts[1]
        return $uri.AbsolutePath
    } catch {
        return $null
    }
}

function Get-OpenConnectHttpDocumentType {
    param(
        [string] $RequestPath
    )

    switch ($RequestPath) {
        '/global-protect/prelogin.esp' { return 'global_protect_prelogin' }
        '/global-protect/getconfig.esp' { return 'global_protect_getconfig' }
        '/ssl-vpn/login.esp' { return 'ssl_vpn_login' }
        '/ssl-vpn/getconfig.esp' { return 'ssl_vpn_getconfig' }
        '/ssl-vpn/hipreportcheck.esp' { return 'ssl_vpn_hipreportcheck' }
        default { return 'unknown' }
    }
}

function Test-OpenConnectXmlBodyLine {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    return ($Line -match '^\s*(?:<\s+)?<(\?xml\b|/?[A-Za-z_:][^>]*)')
}

function Get-OpenConnectXmlBodyContent {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    if ($Line -match '^\s*<\s+(<.*)$') {
        return $Matches[1]
    }

    return $Line.TrimStart()
}

function New-OpenConnectHttpCaptureState {
    param(
        [bool] $Enabled = $false
    )

    return @{
        Enabled = $Enabled
        Status = if ($Enabled) { 'missing' } else { 'disabled' }
        LastUpdated = $null
        CurrentRequestPath = $null
        CurrentDocumentType = $null
        CurrentContentType = $null
        CurrentContentLength = $null
        CurrentHeadersSeen = $false
        AwaitingXmlBody = $false
        BodyActive = $false
        CurrentBodyLines = New-Object System.Collections.ArrayList
        Documents = New-Object System.Collections.ArrayList
    }
}

function New-OpenConnectHttpDocumentMetadata {
    param(
        [string] $RequestPath,
        [string] $DocumentType,
        [string] $CaptureStatus,
        [string] $ParserStatus,
        [string] $RootElement,
        [Nullable[int]] $ContentLength,
        [int] $BodyLineCount
    )

    return [PSCustomObject]@{
        RequestPath = $RequestPath
        DocumentType = $DocumentType
        CaptureStatus = $CaptureStatus
        ParserStatus = $ParserStatus
        RootElement = $RootElement
        ContentLength = $ContentLength
        BodyLineCount = $BodyLineCount
    }
}

function Get-OpenConnectHttpXmlDocumentMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RequestPath,

        [Parameter(Mandatory = $true)]
        [string] $DocumentType,

        [AllowNull()]
        [Nullable[int]] $ContentLength,

        [Parameter(Mandatory = $true)]
        [string[]] $BodyLines
    )

    $xmlText = ($BodyLines -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($xmlText)) {
        return (New-OpenConnectHttpDocumentMetadata -RequestPath $RequestPath -DocumentType $DocumentType -CaptureStatus 'headers_only' -ParserStatus 'not_captured' -ContentLength $ContentLength -BodyLineCount 0)
    }

    try {
        $document = New-Object System.Xml.XmlDocument
        $document.LoadXml($xmlText)
        return (New-OpenConnectHttpDocumentMetadata -RequestPath $RequestPath -DocumentType $DocumentType -CaptureStatus 'body_captured' -ParserStatus 'parsed' -RootElement $document.DocumentElement.Name -ContentLength $ContentLength -BodyLineCount $BodyLines.Count)
    } catch {
        return (New-OpenConnectHttpDocumentMetadata -RequestPath $RequestPath -DocumentType $DocumentType -CaptureStatus 'body_captured' -ParserStatus 'failed' -ContentLength $ContentLength -BodyLineCount $BodyLines.Count)
    }
}

function Write-OpenConnectHttpBodyDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BodyDumpFile,

        [Parameter(Mandatory = $true)]
        [psobject] $Document,

        [Parameter(Mandatory = $true)]
        [string[]] $BodyLines
    )

    $directory = Split-Path -Parent $BodyDumpFile
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $header = '=== BEGIN HTTP XML BODY {0} [{1}] ({2}) ===' -f $Document.RequestPath, $Document.DocumentType, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $footer = '=== END HTTP XML BODY {0} ===' -f $Document.RequestPath
    $payload = @($header) + @($BodyLines) + @($footer, '')
    $content = ($payload -join [Environment]::NewLine) + [Environment]::NewLine
    [System.IO.File]::AppendAllText($BodyDumpFile, $content, [System.Text.UTF8Encoding]::new($false))
}

function Complete-OpenConnectHttpCaptureState {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $CaptureState,

        [string] $BodyDumpFile
    )

    if (-not $CaptureState.Enabled -or [string]::IsNullOrWhiteSpace($CaptureState.CurrentRequestPath)) {
        return
    }

    $document = if ($CaptureState.CurrentBodyLines.Count -gt 0) {
        Get-OpenConnectHttpXmlDocumentMetadata -RequestPath $CaptureState.CurrentRequestPath -DocumentType $CaptureState.CurrentDocumentType -ContentLength $CaptureState.CurrentContentLength -BodyLines @($CaptureState.CurrentBodyLines)
    } elseif ($CaptureState.CurrentHeadersSeen) {
        New-OpenConnectHttpDocumentMetadata -RequestPath $CaptureState.CurrentRequestPath -DocumentType $CaptureState.CurrentDocumentType -CaptureStatus 'headers_only' -ParserStatus 'not_captured' -ContentLength $CaptureState.CurrentContentLength -BodyLineCount 0
    } else {
        $null
    }

    if ($document) {
        [void] $CaptureState.Documents.Add($document)
        if ($document.CaptureStatus -eq 'body_captured' -and $BodyDumpFile) {
            Write-OpenConnectHttpBodyDocument -BodyDumpFile $BodyDumpFile -Document $document -BodyLines @($CaptureState.CurrentBodyLines)
        }
    }

    if (@($CaptureState.Documents | Where-Object { $_.ParserStatus -eq 'failed' }).Count -gt 0) {
        $CaptureState.Status = 'failed'
    } elseif (@($CaptureState.Documents | Where-Object { $_.CaptureStatus -eq 'body_captured' }).Count -gt 0) {
        $CaptureState.Status = 'body_captured'
    } elseif ($CaptureState.Documents.Count -gt 0) {
        $CaptureState.Status = 'headers_only'
    } elseif ($CaptureState.Enabled) {
        $CaptureState.Status = 'missing'
    }

    $CaptureState.CurrentRequestPath = $null
    $CaptureState.CurrentDocumentType = $null
    $CaptureState.CurrentContentType = $null
    $CaptureState.CurrentContentLength = $null
    $CaptureState.CurrentHeadersSeen = $false
    $CaptureState.AwaitingXmlBody = $false
    $CaptureState.BodyActive = $false
    $CaptureState.CurrentBodyLines = New-Object System.Collections.ArrayList
}

function Add-OpenConnectHttpCaptureLine {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $CaptureState,

        [Parameter(Mandatory = $true)]
        [string] $Component,

        [Parameter(Mandatory = $true)]
        [string] $Stream,

        [Parameter(Mandatory = $true)]
        [string] $RawLine,

        [Parameter(Mandatory = $true)]
        [string] $NormalizedLine,

        [Parameter(Mandatory = $true)]
        [string] $DumpFile,

        [string] $BodyDumpFile
    )

    if (-not $CaptureState.Enabled) {
        return $false
    }

    if (Test-OpenConnectHttpRequestLine -Line $NormalizedLine) {
        Complete-OpenConnectHttpCaptureState -CaptureState $CaptureState -BodyDumpFile $BodyDumpFile
        Write-RawLogLine -Component $Component -Stream $Stream -Message $RawLine -LogPath $DumpFile
        $CaptureState.LastUpdated = Get-Date
        $CaptureState.CurrentRequestPath = Get-OpenConnectHttpRequestPath -Line $NormalizedLine
        $CaptureState.CurrentDocumentType = Get-OpenConnectHttpDocumentType -RequestPath $CaptureState.CurrentRequestPath
        $CaptureState.CurrentHeadersSeen = $true
        if ($CaptureState.Status -eq 'missing') {
            $CaptureState.Status = 'headers_only'
        }
        return $true
    }

    if (Test-OpenConnectHttpDumpLine -Line $NormalizedLine) {
        Write-RawLogLine -Component $Component -Stream $Stream -Message $RawLine -LogPath $DumpFile
        $CaptureState.LastUpdated = Get-Date
        $CaptureState.CurrentHeadersSeen = $true

        if ($NormalizedLine -match '^Content-Type:\s*(.+)$') {
            $CaptureState.CurrentContentType = $Matches[1].Trim()
        }

        if ($NormalizedLine -match '^Content-Length:\s*(\d+)$') {
            $CaptureState.CurrentContentLength = [int] $Matches[1]
        }

        if ($NormalizedLine -match '^HTTP body length:\s*\((\d+)\)$') {
            $CaptureState.CurrentContentLength = [int] $Matches[1]
            $CaptureState.AwaitingXmlBody = ($CaptureState.CurrentContentType -like 'application/xml*')
        }

        if ($CaptureState.Status -eq 'missing') {
            $CaptureState.Status = 'headers_only'
        }
        return $true
    }

    if (($CaptureState.AwaitingXmlBody -or $CaptureState.BodyActive) -and (Test-OpenConnectXmlBodyLine -Line $NormalizedLine)) {
        $xmlBodyLine = Get-OpenConnectXmlBodyContent -Line $NormalizedLine
        $CaptureState.BodyActive = $true
        $CaptureState.AwaitingXmlBody = $true
        [void] $CaptureState.CurrentBodyLines.Add($xmlBodyLine)
        $CaptureState.LastUpdated = Get-Date
        return $true
    }

    return $false
}

function Get-OpenConnectHttpCapturePlanMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $CaptureState,

        [string] $DumpFile,

        [string] $BodyDumpFile
    )

    $status = [string] $CaptureState.Status
    $blockedReason = $null
    if ($CaptureState.Enabled -and $status -eq 'headers_only') {
        $blockedReason = 'body_not_emitted_by_openconnect'
    }

    return @{
        http_dump_enabled = [bool] $CaptureState.Enabled
        http_config_capture_status = $status
        xml_capture_blocked_reason = $blockedReason
        http_config_dump_file = if ($DumpFile) { [System.IO.Path]::GetFileName($DumpFile) } else { $null }
        http_config_body_file = if ($BodyDumpFile) { [System.IO.Path]::GetFileName($BodyDumpFile) } else { $null }
        http_config_documents = @($CaptureState.Documents)
        http_config_last_updated = if ($CaptureState.LastUpdated) { (Get-Date $CaptureState.LastUpdated -Format 'o') } else { $null }
    }
}

function New-ProcessStartInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Executable,

        [string[]] $Arguments,

        [hashtable] $EnvironmentVariables
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.Arguments = ConvertTo-CommandLineString -Arguments $Arguments
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    if ($EnvironmentVariables) {
        foreach ($key in $EnvironmentVariables.Keys) {
            $value = $EnvironmentVariables[$key]
            if ($null -eq $value) {
                continue
            }

            $psi.EnvironmentVariables[$key] = [string]$value
        }
    }

    return $psi
}

function Start-ChildProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Executable,

        [string[]] $Arguments,

        [hashtable] $EnvironmentVariables
    )

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = New-ProcessStartInfo -Executable $Executable -Arguments $Arguments -EnvironmentVariables $EnvironmentVariables

    try {
        $started = $proc.Start()
        return [PSCustomObject]@{
            Process = $proc
            Started = $started
            Error = $null
        }
    } catch {
        return [PSCustomObject]@{
            Process = $proc
            Started = $false
            Error = $_
        }
    }
}

function Test-OpenConnectConnectedLine {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    $connectedPatterns = @(
        'ESP session established',
        'ESP tunnel connected',
        'Tunnel is up',
        'Set up (?:TUN|TAP|tun)',
        'Setting up (?:TUN|TAP|tun)',
        'Received DNS server',
        'Received split include route',
        'Received split exclude route',
        'Assigned (?:address|IPv4|IPv6)',
        'Connected as '
    )

    foreach ($pattern in $connectedPatterns) {
        if ($Line -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-OpenConnectScriptEnvironment {
    param(
        [string] $RootDir = $RootDir
    )

    $environment = @{}

    if (Get-VpnConfig -ConfigKey 'OpenConnectScriptDryRun' -RootDir $RootDir) {
        $environment['VPNC_SCRIPT_DRY_RUN'] = '1'
    }
    if (Get-VpnConfig -ConfigKey 'OpenConnectScriptSkipDns' -RootDir $RootDir) {
        $environment['VPNC_SCRIPT_SKIP_DNS'] = '1'
    }
    if (Get-VpnConfig -ConfigKey 'OpenConnectScriptSkipRoutes' -RootDir $RootDir) {
        $environment['VPNC_SCRIPT_SKIP_ROUTES'] = '1'
    }
    if (Get-VpnConfig -ConfigKey 'OpenConnectScriptSkipIpv6' -RootDir $RootDir) {
        $environment['VPNC_SCRIPT_SKIP_IPV6'] = '1'
    }

    if ($environment.Count -eq 0) {
        return $null
    }

    return $environment
}

function Test-OpenConnectAuthFailureLine {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    $authFailurePatterns = @(
        'X-Private-Pan-Globalprotect:\s*auth-failed',
        'Unexpected 512 result from server',
        'User input required in non-interactive mode'
    )

    foreach ($pattern in $authFailurePatterns) {
        if ($Line -match $pattern) {
            return $true
        }
    }

    return $false
}

function Test-OpenConnectScriptWarningLine {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    $scriptWarningPatterns = @(
        "Failed to spawn script '.+vpnc-script-win\.js'",
        'Script did not complete within 10 seconds',
        "Script '.+vpnc-script-win\.js' returned error \d+",
        '\[vpnc-script\]\[[^\]]+\]\[run\] Command failed with exit \d+:',
        '\[vpnc-script\]\[[^\]]+\]\[summary\] Completed with accumulated exit code [1-9]\d*'
    )

    foreach ($pattern in $scriptWarningPatterns) {
        if ($Line -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-OpenConnectScriptWarningSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    if ($Line -match '\[vpnc-script\]\[([^\]]+)\]\[run\] Command failed with exit (\d+): (.+)$') {
        return 'VPN network configuration script command failed during {0}. ExitCode={1}; Command={2}; Review vpn_openconnect_raw.log for full output.' -f $Matches[1], $Matches[2], $Matches[3]
    }

    if ($Line -match '\[vpnc-script\]\[([^\]]+)\]\[summary\] Completed with accumulated exit code ([1-9]\d*)$') {
        return 'VPN network configuration script completed with non-zero exit code during {0}. ExitCode={1}; Review vpn_openconnect_raw.log for command-level diagnostics.' -f $Matches[1], $Matches[2]
    }

    if ($Line -match "Script '.+vpnc-script-win\.js' returned error (\d+)") {
        return 'OpenConnect reported vpnc-script-win.js exit code {0}. Review vpn_openconnect_raw.log for the failing command and command output.' -f $Matches[1]
    }

    if ($Line -match "Failed to spawn script '.+vpnc-script-win\.js' for ([^:]+):") {
        return 'OpenConnect reported a vpnc-script-win.js execution failure during {0}. Review vpn_openconnect_raw.log for command-level diagnostics.' -f $Matches[1]
    }

    if ($Line -match 'Script did not complete within 10 seconds') {
        return 'VPN network configuration script exceeded the expected completion window. Review vpn_openconnect_raw.log for the blocking command.'
    }

    return 'VPN network configuration script reported a failure. Review vpn_openconnect_raw.log for detailed command output.'
}

function Try-Parse-OpenConnectSessionExpiry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    if ($Line -match '^Session authentication will expire at (.+)$') {
        $rawExpiry = $Matches[1].Trim()
        $invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
        $styles = [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
        $knownFormats = @(
            'ddd MMM dd HH:mm:ss yyyy',
            'ddd MMM d HH:mm:ss yyyy',
            'ddd, dd MMM yyyy HH:mm:ss zzz',
            'ddd, dd MMM yyyy HH:mm:ss',
            'ddd, d MMM yyyy HH:mm:ss zzz',
            'ddd, d MMM yyyy HH:mm:ss'
        )

        foreach ($format in $knownFormats) {
            try {
                return [datetime]::ParseExact($rawExpiry, $format, $invariantCulture, $styles)
            } catch {
            }
        }

        # Parse with invariant culture first because OpenConnect emits English day/month names.
        try {
            return [datetime]::Parse($rawExpiry, $invariantCulture)
        } catch {
        }

        try {
            return [datetime]::Parse($rawExpiry)
        } catch {
            return $null
        }
    }

    return $null
}

function Get-OpenConnectEventTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    if ($Line -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]') {
        try {
            return [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        } catch {
            return Get-Date
        }
    }

    return Get-Date
}

function Test-OpenConnectNetworkFailureEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    $networkFailurePatterns = @(
        'getaddrinfo failed',
        'Failed to connect to host',
        'Failed to open HTTPS connection',
        'Failed to reconnect to host',
        'Failed to connect to .*:443',
        'No route to host',
        'Connection refused',
        'timed out',
        'host .* could not be resolved',
        'could not be resolved',
        'name or service not known',
        'temporary failure in name resolution'
    )

    foreach ($pattern in $networkFailurePatterns) {
        if ($Line -match $pattern) {
            return $true
        }
    }

    return $false
}
